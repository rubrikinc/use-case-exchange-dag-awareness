# Exchange DAG Awareness - Quick Start

The Exchange DAG Script can be run manually or requires to be setup as a scheduled task on a management host.
The account that this script will run under requires access to both Exchange and Rubrik via Powershell.

This script will achieve the following:

* Connect to Rubrik and Exchange via Powershell
* Determine the Active and Passive Location of the DAG Exchange Database
* Determine the Drives that the Databases belong to
* Instantiate a backup event of the drives
* Perform a volume level snapshot of the drives discovered
* Confirmed Event Logs showing VSS Event and log truncation

This script requires the following pre-requisites installed on the management host its running on:

* Rubrik Powershell Module - Refer to the Powershell SDK Github (https://github.com/rubrikinc/rubrik-sdk-for-powershell)
* Exchange Powershell Module - Refer to Microsoft Guides to installing the relevant Powershell Module for the version of exchange in your environment

This has been tested against Exchange 2013+

## Caveats

* This will only work when the active database is on it's own windows volume and logs on their own windows volume
* This will not work in scenarios whereby exchange databases for both active and passive are on the same volume or multiple databases are on the same volume

## Configuring the script

The following variables are required to be set inside `backup_exchange_dag.ps1`:

```
$rubrik_ip = '0.0.0.0' # This is the Rubrik IP or DNS Address to connect to the Rubrik API
$exchange_host = 'exch-dag01.exctest.local' # This is the Exchange IP or DNS Address to connect to Exchange via Powershell
$rubrik_user = 'notauser' # This is the Rubrik Username for instantiating the backup
$rubrik_pass = 'notapass' # This is the Rubrik Password for instantiating the backup
$csv_file = './dag_backups.csv' # This is an output CSV file to audit all backup events and which active DB in the DAG was protected
​$host_names = @( 
  'exch-dag01',
  'exch-dag02'
) # This is a list of the hostnames that belong to the DAG that were are protecting
$sla_domain_name = 'Gold' # Rubrik SLA to use during protection tasks # This is the name of the Rubrik SLA that will use during the protection task
```