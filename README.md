# Log Analytics Automation Runbook: sync all subscription objects to a Log Analytics Workspace

When you are designing Log Analytics Queries using Kusto, there are some important use cases where you need to know the existence of certain object types.
For instance:

* Report which VMs do or do not have active antivirus. To get a reliable result you need to include the VMs that do _not_ report to Log Analytics (yet). This solution gets you the required list of all VMs.
* Get the list of all Storage Accounts, and flag which ones do not report to Log Analytics.
* etc.

Use the button below to deploy directly to Azure. 

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fwkasdorp%2FOMSAllSubscriptionResources%2Fmaster%2Fazuredeploy.json" target="_blank">
    <img src="http://azuredeploy.net/deploybutton.png"/>
</a>
