Import-Module Rubrik

function Get-RubrikHostVolumes($host_id) {
  $payload = @{
    "query" = "query HostWithSnappables(`$id: String!) { `
      host(id: `$id) { `
        id `
        volumeGroup { ` `
          volumes { `
            mountPoints `
            id `
          } `
          id `
        } `
      } `
    }";
    "variables" = @{
      "id" = $host_id
    }
  }
  $response = Invoke-RubrikRESTCall -Endpoint 'graphql' -api internal -Method POST -Body $payload
  return $response.data.host.volumeGroup.volumes
}
### Script Configuration Details

$rubrik_ip = '0.0.0.0' # Rubrik DNS or IP Address
$exchange_host = 'exch-dag01.exctest.local' # Exchange Server DNS or IP Address
$rubrik_user = 'notauser' # Rubrik User for basic auth
$rubrik_pass = 'notapass' # Rubrik Password for basic auth - This can be converted to a secure cred xml
$csv_file = './dag_backups.csv' # Output CSV File
$host_names = @(
  'exch-dag01',
  'exch-dag02'
) # List of hosts in the exchange DAG
$sla_domain_name = 'Gold' # Rubrik SLA to use during protection tasks

### End of Script Configuration Details

$backup_date = date
$csv_data = @()

if(Test-Path -Path $csv_file){
  #File Exists
  write-host "File Exists"
} else {
  #File doesn't exist, create it
  New-Item -Path $csv_file -ItemType File
  Add-Content -Path $csv_file -Value '"Date","Server","Database","Drive","State"'
}

Connect-Rubrik -Server $rubrik_ip -Username $rubrik_user -Password $(ConvertTo-SecureString -String $rubrik_pass -AsPlainText -Force) | Out-Null

$sla_id = Get-RubrikSLA -PrimaryClusterID local -Name $sla_domain_name | Select-Object -ExpandProperty id

$hosts = @()
foreach ($host_name in $host_names) {
  $host_object = New-Object PSCustomObject
  $host_object | Add-Member -MemberType NoteProperty -Name 'serverName' -Value $host_name
  $host_info = Get-RubrikHost -Name $host_name -PrimaryClusterId local
  $host_object | Add-Member -MemberType NoteProperty -Name 'id' -Value $host_info.id
  $vol_group = Get-RubrikVolumeGroup -name $host_name -PrimaryClusterID local
  $host_object | Add-Member -MemberType NoteProperty -Name 'volumeGroupId' -Value $vol_group.id
  $host_volumes = Get-RubrikHostVolumes($host_info.id)
  $host_object | Add-Member -MemberType NoteProperty -Name 'volumeDetails' -Value $host_volumes
  $host_object | Add-Member -MemberType NoteProperty -Name 'exchangeDatabase' -Value @()
  $host_object | Add-Member -MemberType NoteProperty -Name 'drivesToBackup' -Value @()
  $hosts += $host_object
}

# GET EXCHANGE DETAILS
Function Connect-Exchange {
  param(
    [Parameter( Mandatory=$true)]
    [string]$URL
  )
  $Credentials = Get-Credential -Message "Enter your Exchange admin credentials"
  $ExOPSession = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://$URL/PowerShell/ -Authentication Kerberos -Credential $Credentials
  Import-PSSession $ExOPSession
}
Connect-Exchange -URL $exchange_host
# make sure all our exchange hosts are in a DAG
$all_servers_in_dag = $true
$dag_members = Get-DatabaseAvailabilityGroup
if ($dag_members) {
  foreach ($host_name in $host_names) {
    if ($host_name.ToUpper() -notin $dag_members.servers.ToUpper()) {
      $all_servers_in_dag = $false
    }
  }
}
if (-not $all_servers_in_dag) {
  throw 'Not all Exchange hosts passed were found in a DAG'
}
$drives_to_backup = @()
# now we get the rest of the details
foreach ($host_name in $host_names) {
  $databases = Get-MailboxDatabase -server $host_name -Status
  if ($databases) {
    $backup_list = @()
    foreach ($database in $databases) {
      $healthy_copy_exists = $false
      $local_active_copy = $false
      $type = $database.ReplicationType
      if ($type -eq 'Remote') {
        # get copy status for each database
        $statuses = Get-MailboxDatabaseCopyStatus $database.Name
        if ($statuses) {
          foreach($status in $statuses) {
            # look if a healthy copy exists
            if ($status.Status -eq "Healthy") {
              $healthy_copy_exists = $true
              if ($status.Name.toUpper().Contains($host_name.toUpper())) {
                # Back Up Healthy Passive Database Copy
                $backup_list += $database
              }
            } elseif ($status.Status -eq "Mounted") {
              # check for local active database copy
              if ($status.Name.toUpper().Contains($host_name.toUpper())) {
                $local_active_copy = $true
              }
            }
          }
          # if a healthy copy does not exist, backup local active
          if ((!$healthy_copy_exists) -and ($local_active_copy)) {
            # Back Up Local Active Database Copy (no healthy copy)
            $backup_list += $database
          }
        }
      } else { # non replicated local database
        # skip local recovery databases
        if (!$database.Recovery -and $database.Mounted) {
          # Backup Up Non Replicated Database
          <#
          ====== TH [2019-02-28] I am removing the backup non-replicated DBs thing right now,
          ====== uncomment below to re-add it
          $backup_list += $database
          #>
        } else {
          if ($database.Recovery) {
            # Skip Recovery Database
          } else {
            # Skip Dismounted Non Replicated Database
          }
        }
      }
    }
  }
  foreach ($db in $backup_list) {
    $this_db = New-Object PSCustomObject
    $this_db | Add-Member -MemberType NoteProperty -Name 'serverName' -Value $host_name
    $this_db | Add-Member -MemberType NoteProperty -Name 'dbName' -Value $db.Name
    $edb_path = $db | select -Expand EdbFilePath
    $log_path = $db | select -Expand LogFolderPath
    $this_db | Add-Member -MemberType NoteProperty -Name 'dbVolume' -Value $($edb_path.split('\')[0]+'\')
    $this_db | Add-Member -MemberType NoteProperty -Name 'logVolume' -Value $($log_path.split('\')[0]+'\')
    $drives_to_backup += $this_db
  }
}
get-pssession | remove-pssession
# END OF GET EXCHANGE DETAILS
foreach ($drive in $drives_to_backup) {
  $this_host = $hosts | ?{$_.serverName -eq $drive.serverName}
  if ($drive.dbVolume -notin $this_host.drivesToBackup) {
    $this_host.drivesToBackup += $drive.dbVolume
  }
  if ($drive.logVolume -notin $this_host.drivesToBackup) {
    $this_host.drivesToBackup += $drive.logVolume
  }
  if ($drive.dbName -notin $this_host.exchangeDatabase) {
    $this_host.exchangeDatabase += $drive.dbName
  }
}

foreach ($server in $hosts) {
  if ($server.drivesToBackup.count -gt 0) {
    Write-Output $('Backing up volumes '+$server.drivesToBackup+' on server '+$server.serverName)
    $volume_ids = @()
    $volume_ids += $server.volumeDetails | Where-Object -Property mountPoints -in $server.drivesToBackup | select-object -ExpandProperty id
    $vol_group_id = $server.volumeGroupId
    $payload = @{
      "slaId" = $sla_id;
      "volumeIdsIncludedInSnapshot" = $volume_ids;
    }
    $snapshot = Invoke-RubrikRESTCall -Endpoint $('volume_group/'+$vol_group_id+'/snapshot') -api 1 -Method POST -Body $payload
    $status = Invoke-RubrikRESTCall -Endpoint $('volume_group/request/'+$snapshot.id) -api 1 -Method GET
    while ($status.status -notin $('SUCCEEDED','FAILURE','WARNING')) {
      Start-Sleep 5
      $status = Invoke-RubrikRESTCall -Endpoint $('volume_group/request/'+$snapshot.id) -api 1 -Method GET
    }
    Write-Output $('Backup of '+$server.serverName+', volumes '+$server.drivesToBackup+' completed with result '+$status)
    $csv_data+="$backup_date,$server.serverName,$server.exchangeDatabase,$server.drivesToBackup,$status`n"
  }
}
$csv_data | foreach {Add-Content -Path $csv_file -Value $_}