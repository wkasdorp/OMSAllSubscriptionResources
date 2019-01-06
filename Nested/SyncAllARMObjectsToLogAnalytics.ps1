# Get information required for the automation account from parameter values when the runbook is started.
Param
(
    [Parameter(Mandatory = $True)]
    [string]$resourceGroupName,
    [Parameter(Mandatory = $True)]
    [string]$automationAccountName
)

$VerbosePreference="continue"

# Authenticate to the Automation account using the Azure connection created when the Automation account was created.
# Code copied from the runbook AzureAutomationTutorial.
$connectionName = "AzureRunAsConnection"
$servicePrincipalConnection=Get-AutomationConnection -Name $connectionName    
Write-Verbose "connecting to automation account"     
Connect-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $servicePrincipalConnection.TenantId `
    -ApplicationId $servicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 


# Get information required for Log Analytics workspace from Automation variables.
$customerId = Get-AutomationVariable -Name 'WorkspaceID'
$sharedKey = Get-AutomationVariable -Name 'WorkspaceKey'

$logType = "WKAllResources"
$subscriptionId = (Get-AzureRmContext).Subscription.Id
$resourceList = @()
Write-Verbose "NOTE: for sure we will need to push data in chunks, the REST body will be limited?"
# TODO: add tag processing, maybe Subscription Name for convenience
$resourceList += Get-AzureRmResource | select -First 100 | ForEach-Object {
   [pscustomobject]@{
       SubscriptionId = $subscriptionId
       ResourceGroupName = $_.ResourceGroupName
       Name = $_.Name
       Location = $_.Location
       ResourceType = $_.ResourceType
    }
} 

if ($resourceList -ne $null) {
    # Convert the job data to json
    $body = $resourceList | ConvertTo-Json

    # Send the data to Log Analytics.
    Write-Verbose "sending data to LA"
    Send-OMSAPIIngestionFile -customerId $customerId -sharedKey $sharedKey -body $body -logType $logType -TimeStampField CreationTime
}
