Param
(
    # target Log Analytics workspace. Must be in the default subscription
    [Parameter(Mandatory = $True)]
    [string]$workspacename,

    # The _case sensitive_ name of the custom log where data is written.
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
    [bool]$AddVmDetails = $true,

    # runcounter Automation Variable Name. This is useful for queries where you want to grab all objects
    # that were present during a given run, but not anything else. 
    [Parameter(Mandatory = $false)]
    [string]$runNumberVariableName = "SyncRunNumber"
)

# maximum number of objects to send in one shot. 30 MB is the max, which should easily hold 10,000 objects
# HOWEVER, with batch sizes larger than 100 we are seeing memory problems with Azure Runbook Sandboxes, which
# are limited to 400 MB Max. So for now it's set to 100 even though larger sizes would be more efficient. 
$batchSize = 100

#
# import modules before we start verbose mode... 
#
$verbosePreferenceBefore=$VerbosePreference
$VerbosePreference="silentlycontinue"
Import-Module AzureRM.Profile
Import-Module AzureRM.Resources 
Import-Module AzureRM.Compute 
Import-Module AzureRM.Automation
$verbosePreference=$verbosePreferenceBefore

#
# Logging on/off
#
$VerbosePreference="continue"

Write-Verbose "- workspacename          : $workspacename"
Write-Verbose "- logname                : $logName"
Write-Verbose "- subscriptionIdList     : "
$subscriptionIDList | ForEach-Object { Write-Verbose "-- $($_.Guid)" }
Write-Verbose "- tagNameList            : $($tagnameList -join ', ')"
Write-Verbose "- AddVmDetails           : $addVmDetails"
Write-Verbose "- runNumberVariableName  : $runNumberVariableName"

#region Cloned Module https://www.powershellgallery.com/packages/OMSIngestionAPI/1.6.0
# Needed to avoid having to add modules to the automation account.  
# renamed function to avoid potential conflicts, added some error checking.

#PowerShell Module leveraged for ingesting data into Log Analytics API ingestion point
<# 
.SYNOPSIS 
    Builds an OMS authorization to securely communicate to a customer workspace. 
.DESCRIPTION 
    Leveraging a customer workspaceID and private key for Log Analytics 
    this function will build the necessary api signature to securely send 
    json data to the OMS ingestion API for indexing 
.PARAMETER customerId 
    The customer workspace ID that can be found within the settings pane of the 
    OMS workspace. 
.PARAMETER sharedKey 
    The primary or secondary private key for the customer OMS workspace 
    found within the same view as the workspace ID within the settings pane 
.PARAMETER date 
    RFC 1123 standard UTC date string converted variable used for ingestion time stamp 
.PARAMETER contentLength 
    Body length for payload being sent to the ingestion endpoint 
.PARAMETER method 
    Rest method used (POST) 
.PARAMETER contentType 
    Type of data being sent in the payload to the endpoint (application/json) 
.PARAMETER resource 
    Path to send the logs for ingestion to the rest endpoint 
#>
Function Get-OMSAPISignatureCloned
{
    Param
    (
        [Parameter(Mandatory = $True)]$customerId,
        [Parameter(Mandatory = $True)]$sharedKey,
        [Parameter(Mandatory = $True)]$date,
        [Parameter(Mandatory = $True)]$contentLength,
        [Parameter(Mandatory = $True)]$method,
        [Parameter(Mandatory = $True)]$contentType,
        [Parameter(Mandatory = $True)]$resource
    )

    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
    return $authorization
}
<# 
.SYNOPSIS 
    Sends the json payload securely to a customer workspace leveraging a 
    customer ID and shared key 
.DESCRIPTION 
    Leveraging a customer workspaceID and private key for Log Analytics 
    this function will send a json payload securely to the OMS ingestion 
    API for indexing 
.PARAMETER customerId 
    The customer workspace ID that can be found within the settings pane of the 
    OMS workspace. 
.PARAMETER sharedKey 
    The primary or secondary private key for the customer OMS workspace 
    found within the same view as the workspace ID within the settings pane 
.PARAMETER body 
    json payload 
.PARAMETER logType 
    Name of log to be ingested assigned to JSON payload 
    (will have "_CL" appended upon ingestion) 
.PARAMETER TimeStampField 
    Time data was ingested. If $TimeStampField is defined for JSON field 
    when calling this function, ingestion time in Log Analytics will be 
    associated with that field. 
 
    example: $Timestampfield = "Timestamp" 
 
    foreach($metricValue in $metric.MetricValues) 
    { 
        $sx = New-Object PSObject -Property @{ 
            Timestamp = $metricValue.Timestamp.ToString() 
            MetricName = $metric.Name; 
            Average = $metricValue.Average; 
            SubscriptionID = $Conn.SubscriptionID; 
            ResourceGroup = $db.ResourceGroupName; 
            ServerName = $SQLServer.Name; 
            DatabaseName = $db.DatabaseName; 
            ElasticPoolName = $db.ElasticPoolName 
        } 
        $table = $table += $sx 
    } 
    Send-OMSAPIIngestionFileCloned -customerId $customerId -sharedKey $sharedKey `
     -body $jsonTable -logType $logType -TimeStampField $Timestampfield 
 
.PARAMETER EnvironmentName 
    If $EnvironmentName is defined for AzureUSGovernment 
    when calling this function, ingestion will go to an Azure Government Log Analytics 
    workspace. Otherwise, Azure Commercial endpoint is leveraged by default. 
#>
Function Send-OMSAPIIngestionFileCloned
{
    Param
    (
        [Parameter(Mandatory = $True)]$customerId,
        [Parameter(Mandatory = $True)]$sharedKey,
        [Parameter(Mandatory = $True)]$body,
        [Parameter(Mandatory = $True)]$logType,
        [Parameter(Mandatory = $False)]$TimeStampField,
        [Parameter(Mandatory = $False)]$EnvironmentName
    )

    #<KR> - Added to encode JSON message in UTF8 form for double-byte characters
    $body=[Text.Encoding]::UTF8.GetBytes($body)
    
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Get-OMSAPISignatureCloned `
     -customerId $customerId `
     -sharedKey $sharedKey `
     -date $rfc1123date `
     -contentLength $contentLength `
     -method $method `
     -contentType $contentType `
     -resource $resource
    if($EnvironmentName -eq "AzureUSGovernment")
    {
        $Env = ".ods.opinsights.azure.us"
    }
    Else
    {
        $Env = ".ods.opinsights.azure.com"
    }
    $uri = "https://" + $customerId + $Env + $resource + "?api-version=2016-04-01"
    if ($TimeStampField.length -gt 0)
    {
        $headers = @{
            "Authorization" = $signature;
            "Log-Type" = $logType;
            "x-ms-date" = $rfc1123date;
            "time-generated-field"=$TimeStampField;
        }
    }
    else {
         $headers = @{
            "Authorization" = $signature;
            "Log-Type" = $logType;
            "x-ms-date" = $rfc1123date;
        }
    } 
    $response = Invoke-WebRequest `
        -Uri $uri `
        -Method $method `
        -ContentType $contentType `
        -Headers $headers `
        -Body $body `
        -UseBasicParsing `
        -verbose
    
    if ($response.StatusCode -ge 200 -and $response.StatusCode -le 299)
    {
        Write-Verbose "Send-OMSAPIINgestionFile: Invoke-WebRequest accepted (status $($response.StatusCode))"
    } else {
        $badStatus = $response.StatusCode
        Write-Verbose "Send-OMSAPIINgestionFile: Invoke-WebRequest ERROR (status $($response.StatusCode))"
        throw "Send-OMSAPIINgestionFile: Invoke-WebRequest returned '$badStatus'"
    }
}
#endregion

#region  Get-LogAnalyticsWorkSpaceKeys
function Get-LogAnalyticsWorkSpaceKeys {
    param($SubscriptionId, $workspaceName)

    #
    # construct authentication from current context. 
    #
    $Context = Get-AzureRmContext
    $ProfileClient = [Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient]::new([Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile);
    $Token = $ProfileClient.AcquireAccessToken($Context.Subscription.TenantId);
    $AuthHeaders = @{
        'Accept' = 'application/json';
        'x-ms-version' = '2014-06-01';
        'Authorization' = "Bearer $($Token.AccessToken)"
    }

    #
    # Find the OMS workspace, get its RG
    # construct REST API parameters.
    # example: https://management.azure.com/subscriptions/0568048c-62e3-485e-bc1b-156f2867e43c/providers/Microsoft.OperationalInsights/workspaces?api-version=2015-11-01-preview
    #
    $Uri = "https://management.azure.com/subscriptions/$($SubscriptionId)/providers/Microsoft.OperationalInsights/workspaces?api-version=2015-11-01-preview"
    $paramIRM = @{
        Uri = $Uri
        Method = 'GET'
        Body = $null
        ContentType = "application/json"
        Headers = $AuthHeaders
        UseBasicParsing = $true
    }
    
    #
    # Call it.
    #
    try {
        Write-Verbose "- calling REST API 'providers/Microsoft.OperationalInsights/workspaces' for '$workspaceName'"
        $result = Invoke-RestMethod @paramIRM -ErrorAction stop
    }
    catch {
        Write-Host -ForegroundColor Red ("Error: $($_)")
    } 

    #
    # get the correct workspace, its rg and customer ID.
    #
    $rg = ""
    $workspace = $result.value | Where-Object name -eq $workspaceName
    if (-not $workspace) 
    {
       throw "Could not find workspace $workspaceName"
    }
    $customerID = $workspace.properties.customerID
    $workspace.id -match 'resourcegroups/(.*)/providers' | Out-Null
    $rg = $Matches[1]
    if (-not $rg)
    {
        throw "Could not resolve Resource Group somehow"
    }

    # Now we have the subscription, RG and workspace name, get the keys.     
    # construct REST API parameters.
    # https://management.azure.com/subscriptions/0568048c-62e3-485e-bc1b-156f2867e43c/resourcegroups/rg-omstest/providers/Microsoft.OperationalInsights/workspaces/wk-oms2/sharedKeys?api-version=2015-11-01-preview
    #
    $Uri = "https://management.azure.com/subscriptions/$($SubscriptionId)/resourcegroups/$($rg)/providers/Microsoft.OperationalInsights/workspaces/$($workspaceName)/sharedKeys?api-version=2015-11-01-preview"
    $paramIRM = @{
        Uri = $Uri
        Method = 'POST'
        Body = $null
        ContentType = "application/json"
        Headers = $AuthHeaders
        UseBasicParsing = $true
    }
    
    #
    # Call it.
    #
    try {
        Write-Verbose "- calling REST API 'providers/Microsoft.OperationalInsights/workspaces/$($workspaceName)/sharedKeys'"
        $result = Invoke-RestMethod @paramIRM -ErrorAction Stop
    }
    catch {
        Write-Host -ForegroundColor Red ("Error: $($_)")
    }

    #
    # [pscustomobject] @{ primarySharedKey = <key1>, secondarySharedKey = <key2>, customerID = <>id }
    #
    return $result | Add-Member -MemberType NoteProperty -Name customerId -Value $customerID -PassThru
}
#endregion

#region Authentication and Keys
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
    -SubscriptionID $servicePrincipalConnection.SubscriptionId `
    -ErrorAction Stop

Write-Verbose "- Authentication succeeded. "
Write-Verbose "- getting Log Analytics workspace $($workspacename) and its key using REST API calls."
$workspaceKeys = Get-LogAnalyticsWorkSpaceKeys -SubscriptionId (Get-AzureRmContext).Subscription.id -workspaceName $workspacename
$customerId = $workspaceKeys.customerId
$sharedKey = $workspaceKeys.PrimarySharedKey
#endregion

#
# get and increase the runnumber.
# Example usage of query using runnumber (customlog name is WKLog10_CL). This gets all objects
# that were present when the inventory was run. 
# WKLog10_CL 
# | summarize runNumber = arg_max(RunNumber_d, *) by ResourceId
# | where ResourceType == "Microsoft.Compute/virtualMachines"
# | project TimeGenerated,runNumber,Name_s,tag_owner_s, ResourceType, OSType_s, PowerState_s 
#
$runNumber = Get-AutomationVariable -Name $runNumberVariableName -ErrorAction Stop
Write-Verbose "- Current run number: $runNumber"
Set-AutomationVariable -Name $runNumberVariableName -Value $($runNumber + 1)

#
# loop over subscriptions
#
if (-not $subscriptionIDList) {
    $context = Get-AzureRmContext
    $subscriptionIDList = @([guid]$context.Subscription.Id)
    Write-Verbose "- using default subscription of the automation account: $($context.Subscription.Name))"
}
Write-Verbose "- Preparing to write data to log $($logName)."
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
    
    Write-Verbose "-- processing resource list for subscription '$($context.Subscription.Name)' in chunks of $batchSize objects."
    $ResourceGroupList = Get-AzureRmResourceGroup -ErrorAction stop
    Write-Verbose "-- Found $($ResourceGroupList.Count) resource groups."
    
    #
    # writing resource list to disk instead of caching it in memory; we can only use 400 MB memory in a runbook.
    #
    $cacheFile = "$($ENV:Temp)\resourcelist.txt"
    if (Test-Path -Path $cacheFile)
    {
        Remove-Item $cacheFile -Force
        "-- found and removed temp file: $($cachefile)"
    }
    Get-AzureRmResource -ErrorAction stop | Export-Clixml $cacheFile -Force
    Write-Verbose "-- wrote resources to temp file: $($cachefile)"
    
    $resourceList = @()
    $batchCount = 0
    $objectCount = 0
    foreach ($rg in $ResourceGroupList) 
    {
        #
        # first, get the RG details and add that to the output records.
        #
        $record = [pscustomobject]@{
            RunNumber = $runNumber
            SubscriptionId = $subscriptionId.ToString()
            SubscriptionName = $context.Subscription.Name
            ResourceGroupName = $rg.ResourceGroupName
            ResourceID = $rg.ResourceId
            Name = $rg.ResourceGroupName
            Location = $rg.Location
            ResourceType = "(ResourceGroup)"
        }        
        foreach ($tagname in $tagnameList)
        {
            $record | Add-Member -MemberType NoteProperty -Name "tag_$($tagname)" -Value $_.tags.$tagname
        }
        if ($AddVmDetails)
        {
            $record | Add-Member -MemberType NoteProperty -Name "OSType" -Value ""
            $record | Add-Member -MemberType NoteProperty -Name "PowerState" -Value ""
        }
        $resourceList += $record
        $objectCount++
        $batchCount++
        
        #
        # get all the child objects and add the RG reference
        #
        # Start by getting all resources in the RG, and the VM details as well if needed
        # Note: using this construction to avoid 'get-azurermobject -resourcegroup <xx>' which does
        # not work on all Module versions (know bug).
        #
        $objectsInRg = @(Import-Clixml -Path $cacheFile | Where-Object ResourceGroupName -eq $rg.ResourceGroupName)
        if ($AddVmDetails)
        {
            $vmList = Get-AzureRmVM -ResourceGroupName $rg.ResourceGroupName -Status
        }

        #
        # create the output object, add information as required.
        #
        foreach ($resource in $objectsInRg)
        {
             $record = [pscustomobject]@{
                RunNumber = $runNumber
                SubscriptionId = $subscriptionId.ToString()
                SubscriptionName = $context.Subscription.Name
                ResourceGroupName = $rg.ResourceGroupName
                ResourceID = $resource.ResourceId
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
                $OSType = ""
                $powerState = ""
                $vm = $vmList | Where-Object id -eq $resource.id                
                if ($vm)
                {
                    $OSType = [string]$vm.StorageProfile.OsDisk.OsType
                    $powerState = [string]$vm.PowerState
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
        # full count of the objects in the resource group. Since the maximum objects in an RG is 900, the total count
        # can reach at least 1800 before flushing (current RG plus the previous one.).
        #
        if ($batchCount -ge $batchSize)
        {
            Write-Verbose "-- Batch count reached $batchCount, now writing to the workspace. Total object count: $objectCount"
            $body = $resourceList | ConvertTo-Json
            try {
                Send-OMSAPIIngestionFileCloned -customerId $customerId -sharedKey $sharedKey -body $body -logType $logName -TimeStampField CreationTime
            } catch {
                $ErrorMessage = $_.Exception.Message
                throw "Failed to write data to OMS workspace for subscription '$subscriptionID': $ErrorMessage"        
            }
            Remove-Variable resourceList
            $resourceList = @()
            $batchCount = 0
            
            #
            # try to clean up memory.
            #
            [System.GC]::GetTotalMemory(‘forcefullcollection’) | out-null
        }
    }  

    #
    # Flush any leftover records after processing the subscription. 
    #
    if ($batchCount -gt 0)
    {
        Write-Verbose "-- Flushing final $batchCount objects to the workspace. Total object count: $objectCount"
        $body = $resourceList | ConvertTo-Json
        Send-OMSAPIIngestionFileCloned -customerId $customerId -sharedKey $sharedKey -body $body -logType $logName -TimeStampField CreationTime
    }
    Write-Verbose "-- Wrote total $objectCount objects for subscription '$($context.Subscription.Name)'"
}

exit 0