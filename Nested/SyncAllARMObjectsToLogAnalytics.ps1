# Get information required for the automation account from parameter values when the runbook is started.
Param
(
    [Parameter(Mandatory = $True)]
    [string]$workspacename,
    [Parameter(Mandatory = $True)]
    [string]$logName,
    [Parameter(Mandatory = $false)]
    [Guid[]]$subscriptionIDList
)

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
    
    Write-Verbose "-- getting full resource list"

    $resourceList = @()
    Write-Verbose "NOTE: for sure we will need to push data in chunks, the REST body will be limited?"
    # TODO: add tag processing, maybe Subscription Name for convenience
    $resourceList += Get-AzureRmResource | select-object -First 100 | ForEach-Object {
        [pscustomobject]@{
            SubscriptionId = $subscriptionId.ToString()
            SubscriptionName = $context.SubscriptionName
            ResourceGroupName = $_.ResourceGroupName
            Name = $_.Name
            Location = $_.Location
            ResourceType = $_.ResourceType
        }
    } 

    if ($null -ne $resourceList) {
        # Convert the job data to json
        $body = $resourceList | ConvertTo-Json

        # Send the data to Log Analytics.
        Write-Verbose "- sending data to Log Analytics"
        Send-OMSAPIIngestionFile -customerId $customerId -sharedKey $sharedKey -body $body -logType $logName -TimeStampField CreationTime
    }
}