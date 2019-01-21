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
# maximum number of objects to send in one shot. 30 MB is the max.
#
$batchSize = 1000

#
# import modules before we start verbose mode... The OMS one is not present in the account by default. 
#
Import-Module AzureRM.Profile
Import-Module AzureRM.Resources
Import-Module AzureRM.OperationalInsights -ErrorAction stop

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

Write-Verbose "- list of tags to be added to the logfile:"
$tagnameList -join ', ' | Write-Verbose

#
# loop over subscriptions
#
if (-not $subscriptionIDList) {
    Write-Verbose "- using default subscription."
    $subscriptionIDList = @([guid](Get-AzureRmContext).Subscription.Id)
}
Write-Verbose "- Preparing to write data to log $($logName)."
Write-verbose "- looping over subscription(s)."
foreach ($subscriptionID in $subscriptionIDlist)
{
    Write-Verbose "-- setting context"
    $context = Set-AzureRmcontext -subscriptionID $subscriptionID
    
    Write-Verbose "-- getting full resource list for subscription $($context.SubscriptionName)"

    $resourceList = @()
    Write-Verbose "NOTE: for sure we will need to push data in chunks, the REST body will be limited?"
    $resourceList += Get-AzureRmResourceGroup -PipelineVariable rg | ForEach-Object {
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
        $record
    
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
            $record
        }
    }  

    if ($null -ne $resourceList) {
        # Convert the job data to json
        $body = $resourceList | ConvertTo-Json

        # Send the data to Log Analytics.
        Write-Verbose "-- sending data to Log Analytics."
        Send-OMSAPIIngestionFile -customerId $customerId -sharedKey $sharedKey -body $body -logType $logName -TimeStampField CreationTime
    }
}