# Log Analytics Solution: sync all subscription objects to an workspace

When you are designing Log Analytics Queries using Kusto, there are some important use cases where you need to know the existence of certain object types.
For instance:

* Report which VMs do or do not have active antivirus. To get a reliable result you need to include the VMs that do _not_ report to Log Analytics (yet). This solution gets you the required list of all VMs.
* Get the list of all Storage Accounts, and flag which ones do not report to Log Analytics.
* etc.
