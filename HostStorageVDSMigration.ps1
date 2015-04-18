param($vm,$vmlist,$email) #Must be the first statement in your script

## Global Variables.
$dtmToday = ((Get-Date).dateTime).tostring()
$strSubjectLine = "Storage Migration Script Report - $dtmToday"    
$strBodyText = "report attached."
$strSender = "mark_teng@trendmicro.com"
$strRecipient = "mark_teng@trendmicro.com"
$Attachment = ""
$errFile = "d:\script\MigrationErr.txt"
$LogDir = "D:\script\"
$vmToMigrate = ""
$VmSize = ""
## vCenter specific variable.

## function to get actual VM size in datastore
Function Get-VmSize($vm) {
    #Initialize variables
    $VmDirs =@()
    $VmSize = 0

    $searchSpec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
    $searchSpec.details = New-Object VMware.Vim.FileQueryFlags
    $searchSpec.details.fileSize = $TRUE
	$vm_1 = Get-VM $vm
    Get-View -VIObject $vm_1 | % {
        #Create an array with the vm's directories
        $VmDirs += $_.Config.Files.VmPathName.split("/")[0]
        $VmDirs += $_.Config.Files.SnapshotDirectory.split("/")[0]
        $VmDirs += $_.Config.Files.SuspendDirectory.split("/")[0]
        $VmDirs += $_.Config.Files.LogDirectory.split("/")[0]
        #Add directories of the vm's virtual disk files
        foreach ($disk in $_.Layout.Disk) {
            foreach ($diskfile in $disk.diskfile){
                $VmDirs += $diskfile.split("/")[0]
            }
        }
        #Only take unique array items
        $VmDirs = $VmDirs | Sort | Get-Unique

        foreach ($dir in $VmDirs){
            $ds = Get-Datastore ($dir.split("[")[1]).split("]")[0]
            $dsb = Get-View (($ds | get-view).Browser)
            $taskMoRef  = $dsb.SearchDatastoreSubFolders_Task($dir,$searchSpec)
            $task = Get-View $taskMoRef 

            while($task.Info.State -eq "running" -or $task.Info.State -eq "queued"){$task = Get-View $taskMoRef }
            foreach ($result in $task.Info.Result){
                foreach ($file in $result.File){
					$Size += $file.FileSize
					logToFile "Filename: $file has zize of $Size" "$file"
                }
            }
        }
    }
	# Convert Bytes to GB.
	$Size /= 1073741824
	logToFile "TOTAL Size of VM in GB is $Size" "$file"
    return $Size
}

## function to check VM if powerOff, no snapshot and remove CDROM (force)
Function CheckVM([string]$arg1) {
	## get if VM has snapshot
	$snap = get-snapshot -vm $arg1
	# check if  VM has no snapshot and VMTOOLS is installed
	$toolStatus = get-vm "New Virtual Machine Mark" | Get-View | Select-Object @{Name="Status";Expression={$_.Guest.ToolsStatus}}
	logToFile "VMName: $arg1" "$file"
	logToFile "State: $vmState" "$file"
	logToFile "SnapShot (blank means no Snapshot): $snap" "$file"
	logToFile "VMName: $$toolStatus.Status" "$file"
	
	if ($snap -eq $null -and $toolStatus.Status -ne "toolsNotInstalled") {
		logToFile "Removing CDROM attached to VM $arg1" "$file"
		write-host $arg1 "is" $vmState ",no snapshot and no CDROM attached"
		logToFile "$arg1 is $vmState, tools $toolStatus.Status is no snapshot and no CDROM attached" "$file"
		Get-VM $arg1 | Get-CDDrive | Set-CDDrive -NoMedia -Confirm:$false
		logToFile "Removing VM Tools attached to VM $arg1" "$file"
		Dismount-Tools -vm $arg1
		return $true,$vmState
	} else {
		logToFile "Please make sure that VMTools is install and There is no SNAPSHOT" "$file"
		return $false
	}
}

Function Get-HostDatastore($Cluster,$Size) {
	# Get ONE Random Host from Destination Cluster and this will become the destination host.
	logToFile "Get random host from $Cluster" "$file"
	$TempHost = get-vmhost -location $Cluster | where {$_.ConnectionState -eq "Connected"} | get-random | Foreach-Object { $_.Name }
	# Get all datastore connected destination above.
	logToFile "Get all NFS datastore connected to host $TempHost" "$file"
	$AllDatastore = Get-VMHost -name $TempHost | Get-Datastore -name NETAPP_SHARE_* |  where {$_.type -eq "NFS"} | Sort-Object FreeSpaceGB -descending
	# Scan datastore which can accomodate the VM.
	logToFile "Check all datastore where Total Size of VM can be migrated." "$file"
	Foreach ( $dataStore in $AllDatastore ){
		write-host "-------------------------"
		$DSFreeSpace = $dataStore.freespacegb
		$DSCapacity = $dataStore.CapacityGB
		$dataStoreName = $dataStore.name
		write-host "datastore capacity" $DSCapacity
		write-host "datastore free space" $DSFreeSpace
		write-host "datastore NAME" $dataStoreName
		logToFile "DATASTORE NAME: $dataStoreName" "$file"
		logToFile "DATASTORE TOTAL CAPACITY: $DSCapacity" "$file"
		logToFile "DATASTORE FREE SPACE: $DSFreeSpace" "$file"
		## 200GB buffer on every datastore
		$DSCapacity -= 200
		## get datastore actual usage/used space
		$DSUsage = $DSCapacity - $DSFreeSpace
		write-host "datastore current usage" $DSUsage
		write-host "VM SIZE" $Size
		write-host "datastore capacity minus 200" $DSCapacity
		## add VM Total size to Disk Usage
		logToFile "Current Usage of DATASTORE is $DSUsage GB" "$file"
		logToFile "Current Usage of DATASTORE $DSUsage GB + VM $Size GB should be less than than datatore capacity $DSCapacity GB" "$file"
		$DSUsage += "$Size"
		write-host "disk usage of" $dataStoreName "after migration of VM" $DSUsage
		$DatastoreConnection = Get-VmHost -name $TempHost | get-datastore -name $dataStoreName | where {$_.state -ne "Unavailable"}  
		if ( $DSCapacity -gt $DSUsage -and $DatastoreConnection -ne $null) {
			write-host "VM size " $Size
			write-host "capacity of disk after minus 200" $DSCapacity
			write-host "disk space after migration" $DSUsage
			logToFile "Total Usage of Datastore: $dataStoreName will be $DSUsage after migration." "$file"
			return $TempHost,$dataStoreName
		} else {
			write-host "CANNOT MIGRATE"
			write-host "VM size " $Size
			write-host "capacity of disk after minus 200" $DSCapacity
			write-host "disk space after migration" $DSUsage
			logToFile "Cannot migrate to Datastore: $dataStoreName" "$file"
			logToFile "Total Usage after migration: $DSUsage" "$file"
		}
	}
}

function logToFile($log,$logfile) {
	$curDate = ((Get-Date).dateTime).tostring()
	$log = $curDate + " : " + $log
	$log | out-file -Filepath $logfile -append
}

Function ChangePortGroup ($arrVmVLanInfo) {
	$len = $arrVmVLanInfo.Length
	for ($i=0; $i -lt $len; $i++) {
		$VMNetworkName = $arrVmVLanInfo[$i]
		$i++
		$NetworkVlanID = $arrVmVLanInfo[$i]
		logToFile "$vmToMigrate Network Name: $VMNetworkName" "$file"
		logToFile "$vmToMigrate VLANID: $NetworkVlanID" "$file"
		logToFile "Getting vDS Port group name using with the same VLANID of VM in vSS: $NetworkVlanID" "$file"
		$DestinationPortGroup = Get-VDPortgroup | where {$_.VlanConfiguration -match $NetworkVlanID}
		logToFile "$DestinationPortGroup port group in vDS has the same vSS VLANID of $vmToMigrate" "$file"
		write-host $VMNetworkName $NetworkVlanID $DestinationPortGroup
		logToFile "Change port of $vmToMigrate from vSS to vDS" "$file"
		logToFile "FROM: $VMNetworkName $NetworkVlanID" "$file"
		logToFile "TO: $DestinationPortGroup" "$file"
		# assign vDS port to VM reference the VLANID from vSS.
		Get-NetworkAdapter -VM $vmToMigrate | where {$_.NetworkName -eq $VMNetworkName} | set-networkadapter -portgroup $DestinationPortGroup -confirm:$false
		logToFile "Change of Port Group to vDS of $vmToMigrate to $DestinationPortGroup completed" "$file"
	}
}

Function MigrateVM($vm,$cluster,$buffer) {
	$vmToMigrate = $vm
	$OrigVmDatastore = Get-VM $vmToMigrate | Get-Datastore | Foreach-Object { $_.Name }
	$OrigCluster = Get-VM $vmToMigrate | Get-Cluster | Foreach-Object { $_.Name }
	## check vm if its powerOff, no snapshot and no cdrom. If one of them FAIL script will exit and not continue.
	if (CheckVM($vmToMigrate)) {
		# Get TOTAL size of VM.
		$VmSize = Get-VmSize($vmToMigrate)
		write-host $vmToMigrate "has" $VmSize
		logToFile "Total Size of $vmToMigrate of $VmSize" "$file"
		Write-host "Getting VLANID Information of" $vmToMigrate "before migrating"
		logToFile "Getting VLANID information of $vmToMigrate before migrating" "$file"
		# Get NetworkName before migrating as it will be blank after migratin to vDS
		$ALLVmVlanInfo = Get-NetworkAdapter -VM $vmToMigrate | Foreach-Object { $_.NetworkName }
		
		# Array where VLANID and NetworkName is saved.
		$arrPGInfo = @()
		# Get VLANID and NetworkName of VM. This will be used after migration as vDS is not yet avaiable in originating host.
		Foreach ( $VlanInfo in $ALLVmVlanInfo ) {
			## get VLAN ID
			$arrPGInfo += $VlanInfo
			# get VLANID of VM in vSS and will be use later to reference in vDS's VLANID
			$temp = Get-VirtualPortGroup -vm $vmToMigrate -name $VlanInfo | Foreach-Object { $_.vlanid }
			$arrPGInfo += $temp
		}

		## if Variable $buffer is NOT EMPTY and $cluster is not empty it means the VM is Migrating Online.
		## VM will be migrated to Buffer cluster then to NEW CLUSTER after.
		## if $buffer is EMPTY it means the machine will be offline migration.
		if ($buffer -ne $null -and $cluster -ne $null ) {
			# get host and datastore where VM will be migrated.
			$DestHost,$DestDatastore = Get-HostDatastore -Cluster "$buffer" -Size "$VmSize"
			# migrate VM to buffer ESX host and datastore with EagerZeroedThick disk format.
			move-vm -vm $vmToMigrate -destination $DestHost -datastore $DestDatastore -DiskStorageFormat EagerZeroedThick -Confirm:$false
			logToFile "$vmToMigrate has been migrated to $DestHost and using $DestDatastore" "$file"
			write-host $vmToMigrate "has been migrated to" $DestHost " and using" $DestDatastore
			
			## Change Port group of VM and if returns $true will proceed on migrating to new cluster.
			if (ChangePortGroup($arrPGInfo)) {
				## Migrate to NEW Cluster
				write-host "migrating" $vmToMigrate "to" $cluster
				move-vm -vm $vmToMigrate -destination $cluster -Confirm:$false
				write-host $vmToMigrate "is now in" $cluster "using" $DestDatastore "with vDS"
			}
		} else {
			# get host and datastore where VM will be migrated.
			$DestHost,$DestDatastore = Get-HostDatastore -Cluster "$cluster" -Size "$VmSize"
			move-vm -vm $vmToMigrate -destination $DestHost -datastore $DestDatastore -DiskStorageFormat EagerZeroedThick -Confirm:$false
			if (ChangePortGroup($arrPGInfo)) {
				write-host $vmToMigrate "is now in" $DestHost "using" $DestDatastore "with vDS"
			}
		}
		logToFile "VM Migration of $vmToMigrate has been completed" "$file"
		return $true
	} else {
		return $false
	}
	
}

if ($vmlist -eq $null -and $vm -eq $null) {
	write-host "ERROR: VM or vmlist Parameter do not have value. No VM to migrate."
	logToFile "START of SCRIPT" "$errFile"
	logToFile "ERROR: VM or File Parameter do not have value. No VM to migrate." "$errFile"
} elseif ($vmlist -ne $null -and $vm -ne $null) {
	write-host "ERROR: VM and vmlist Parameter has value."
	logToFile "START of SCRIPT" "$errFile"
	logToFile "ERROR: VM and File Parameter has value." "$errFile"
} else {
	$dc = Get-Datacenter 
	switch ($dc){ 
		SJC1 {
			$BufferCluster = "SJC1_Buffer"
			$DestinationCluster = ""
			}
		MUC1 { 
			$BufferCluster = "MUC1_Buffer"
			$DestinationCluster = "MUC1_Cluster03_NFS"
			}
		SJDC { 
			$profile_name = "SJDC_Standard_Setting"
			$DestinationCluster = ""
			}
		IAD1 { 
			$profile_name = "IAD1_Standard_Setting"
			$DestinationCluster = ""
			}
		UDC2 { 
			$profile_name = "YY_Standard_Setting"
			$DestinationCluster = ""
			}
		default {
			Write-host "Please login first in any datacenter"
			}
	}

	if ( $vmlist -ne $null ) {
		$vmhost_array = Get-Content $vmlist
	} else {
		$vmhost_array = $vm 
	}
	
	Foreach ( $vm in $vmhost_array ) {
		$file = "$LogDir" + "$vm" + "_" + "$(get-date -format `"yyyyMMdd_hhmmtt`").txt"
		## get vm powerState. 
		$vmState = Get-VMGuest $vm | Foreach-Object { $_.State }
		if ( $vmState -eq "Running" ) {
			if ( MigrateVM -vm $vm -buffer $BufferCluster -cluster $DestinationCluster) {
				write-host "Online migration has been completed."
				logToFile "Online migration has been completed." "$file"
			} else {
				write-host "migration to buffer cluster fail. Please check if CDROM is inserted/attached. Check snaphost. Check if vmtools is installed"
				logToFile "migration to buffer cluster fail. Please check if CDROM is inserted/attached. Check snaphost. Check if vmtools is installed" "$file"
			}
		} else {
			if ( MigrateVM -vm $vm -cluster $DestinationCluster) {
				write-host "Successfully Migrate" $vm "to New Cluster"
				logToFile "Successfully Migrate $vm to New Cluster" "$file"
			} else {
				write-host "Migration to New Cluster Fail"
				logToFile "Migration to New Cluster Fail" "$file"
			}
		}
	}
	$date = ((Get-Date).dateTime).tostring()
	write-host $date

}