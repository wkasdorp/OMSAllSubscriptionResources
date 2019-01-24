# Get information required for the automation account from parameter values when the runbook is started.
Param
(
    # target Log Analytics workspace
    [Parameter(Mandatory = $True)]
    [string]$workspacename,

    # name of the custom log where data is written.
    [Parameter(Mandatory = $True)]
    [string]$logName,
    
    # List of subscriptions (GUIDs) to sync. Default: subscripion of the automation account. 
    # runbook input example: ["4d0761b7-6383-47c3-8398-0fb138fb4b46","0568048c-62e3-485e-bc1b-156f2867e43c"]
    [Parameter(Mandatory = $false)]
    [Guid[]]$subscriptionIDList,
    
    # List of tag names to sync. Each name will have its own column.
    # runbook input example: ["owner","bo-number"]
    [Parameter(Mandatory = $false)]
    [String[]]$tagnameList,
    
    # add some VM details: OStype, Powerstate
    [Parameter(Mandatory = $false)]
    [bool]$AddVmDetails = $false
)

#
# maximum number of objects to send in one shot. 30 MB is the max, which should easily hold 10,000 objects.
#
$batchSize = 1000

#
# import modules before we start verbose mode... The OMS one is not present in the account by default. 
#
Import-Module AzureRM.Profile -Verbose:$false
Import-Module AzureRM.Resources -Verbose:$false
Import-Module AzureRM.Compute -Verbose:$false
Import-Module AzureRM.OperationalInsights -ErrorAction stop -Verbose:$false

#
# Logging on/off
#
$VerbosePreference="continue"

# Authenticate to the Automation account using the Azure connection created when the Automation account was created.
# Code copied from the runbook AzureAutomationTutorial.
$connectionName = "AzureRunAsConnection"
$servicePrincipalConnection=Get-AutomationConnection -Name $connectionName    
Write-Verbose "- Authenticating Service Principal."     
Connect-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $servicePrincipalConnection.TenantId `
    -ApplicationId $servicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
    -ErrorAction Stop

Write-Verbose "- Authentication succeeded. "
Write-Verbose "- getting Log Analytics workspace $($workspacename) and its key."
$workspace = Get-AzureRmOperationalInsightsWorkspace -ErrorAction stop | Where-Object name -eq $workspacename
if (-not $workspace)
{ 
    throw "could not find workspace $workspacename"
}
$workspaceKeys = $workspace | Get-AzureRmOperationalInsightsWorkspaceSharedKeys -ErrorAction Stop
$customerId = $workspace.CustomerId
$sharedKey = $workspaceKeys.PrimarySharedKey

#
# loop over subscriptions
#
Write-Verbose "- list of tags to be added to the logfile:"
$tagnameList -join ', ' | Write-Verbose
if (-not $subscriptionIDList) {
    Write-Verbose "- using default subscription of the automation account."
    $subscriptionIDList = @([guid](Get-AzureRmContext).Subscription.Id)
}
Write-Verbose "- Preparing to write data to log $($logName)."
Write-Verbose "- Add VM status details: $AddVmDetails"
Write-verbose "- looping over subscription(s)."
foreach ($subscriptionID in $subscriptionIDlist)
{
    Write-Verbose "-- setting AzureRM context."
    try {
        $context = Set-AzureRmcontext -subscriptionID $subscriptionID               
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        throw "Failed to authenticate to subscriptionID '$subscriptionID': $ErrorMessage"
    }
    
    Write-Verbose "-- reading full resource list for subscription '$($context.Subscription.Name)' in chunks of $batchSize objects."
    $resourceList = @()
    $batchCount = 0
    $objectCount = 0
    Get-AzureRmResourceGroup -PipelineVariable rg | ForEach-Object {
        #
        # first, get the RG details and add that to the output records.
        #
        $record = [pscustomobject]@{
            SubscriptionId = $subscriptionId.ToString()
            SubscriptionName = $context.SubscriptionName
            ResourceGroupName = $rg.ResourceGroupName
            Name = $rg.ResourceGroupName
            Location = $rg.Location
            ResourceType = "(ResourceGroup)"
        }        
        foreach ($tagname in $tagnameList)
        {
            $record | Add-Member -MemberType NoteProperty -Name "tag-$($tagname)" -Value $_.tags.$tagname
        }
        $resourceList += $record
        $objectCount++
        $batchCount++
        
        #
        # get all the child objects and add the RG reference
        #
        # Start by getting all resources in the RG, and the VM details as well if needed
        #
        $objectsInRg = @(Get-AzureRmResource -ResourceGroupName $rg.ResourceGroupName)
        if ($AddVmDetails)
        {
            $vmList = get-azurermvm -ResourceGroupName $rg.ResourceGroupName -Status
        }

        #
        # create the output object, add information as required.
        #
        foreach ($resource in $objectsInRg)
        {
             $record = [pscustomobject]@{
                SubscriptionId = $subscriptionId.ToString()
                SubscriptionName = $context.SubscriptionName
                ResourceGroupName = $rg.ResourceGroupName
                Name = $resource.Name
                Location = $resource.Location
                ResourceType = $resource.ResourceType
            }            
            foreach ($tagname in $tagnameList)
            {
                $record | Add-Member -MemberType NoteProperty -Name "tag-$($tagname)" -Value $_.tags.$tagname
            }

            #
            # Add VM details to the existing object if there exists such a VM.
            #
            if ($AddVmDetails)
            {
                $vm = $null
                $OSType = $null
                $powerState = $null
                $vm = $vmList | Where-Object id -eq $resource.id                
                if ($vm)
                {
                    $OSType = $vm.StorageProfile.OsDisk.OsType
                    $powerState = $vm.PowerState
                }
                $record | Add-Member -MemberType NoteProperty -Name "OSType" -Value $OSType
                $record | Add-Member -MemberType NoteProperty -Name "PowerState" -Value $powerState
            }
            $resourceList += $record
            $objectCount++
            $batchCount++
        }
        
        #
        # if we reach or exceed the batch size, flush. Note that resourceList at least contains the
        # full count of the objects in the resource group. Since the maximum objects in an RG is 800, the total count
        # can reach at least 1600 before flushing (current RG plus the previous one.).
        #
        if ($batchCount -ge $batchSize)
        {
            Write-Verbose "--- Batch count reached $batchCount, now writing to the workspace. Total object count: $objectCount"
            $body = $resourceList | ConvertTo-Json
            try {
                Send-OMSAPIIngestionFile -customerId $customerId -sharedKey $sharedKey -body $body -logType $logName -TimeStampField CreationTime
            } catch {
                $ErrorMessage = $_.Exception.Message
                throw "Failed to write data to OMS workspace for subscription '$subscriptionID': $ErrorMessage"        
            }
            $resourceList = @()
            $batchCount = 0    
        }
    }  

    #
    # Flush any leftover records after processing the subscription. 
    #
    if ($batchCount -gt 0)
    {
        Write-Verbose "--- Flushing final $batchCount objects to the workspace. Total object count: $objectCount"
        $body = $resourceList | ConvertTo-Json
        Send-OMSAPIIngestionFile -customerId $customerId -sharedKey $sharedKey -body $body -logType $logName -TimeStampField CreationTime
    }
    Write-Verbose "-- Wrote $objectCount objects for subscription '$($context.Subscription.Name)'"
}