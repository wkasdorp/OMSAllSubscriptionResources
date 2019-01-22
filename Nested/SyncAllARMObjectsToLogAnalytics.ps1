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
    # runbook input example: [b40a7802-5e7e-47d1-8011-e2b433bfb04f,0ff9f697-f328-4943-b2f5-54b37ae27f1a]
    [Parameter(Mandatory = $false)]
    [Guid[]]$subscriptionIDList,
    # List of tag names to sync. Each name will have its own column.
    # runbook input example: ["owner","bo-number"]
    [Parameter(Mandatory = $false)]
    [String[]]$tagnameList
)

#
# maximum number of objects to send in one shot. 30 MB is the max, which should easily hold 10,000 objects.
#
$batchSize = 1000

#
# import modules before we start verbose mode... The OMS one is not present in the account by default. 
#
Import-Module AzureRM.Profile
Import-Module AzureRM.Resources
Import-Module AzureRM.OperationalInsights -ErrorAction stop

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
    Write-Verbose "- using default subscription."
    $subscriptionIDList = @([guid](Get-AzureRmContext).Subscription.Id)
}
Write-Verbose "- Preparing to write data to log $($logName)."
Write-verbose "- looping over subscription(s)."
foreach ($subscriptionID in $subscriptionIDlist)
{
    Write-Verbose "-- setting AzureRM context."
    $context = Set-AzureRmcontext -subscriptionID $subscriptionID    
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
        Get-AzureRmResource -ResourceGroupName $rg.ResourceGroupName -PipelineVariable resource | ForEach-Object {
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
                throw "Failed to write to OMS Workspace: $ErrorMessage"
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