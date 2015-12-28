param
(
    [Parameter(Mandatory=$true, ParameterSetName='Prepare')]
    [String] $DomainFQDN, 
        
    [Parameter(Mandatory=$true, ParameterSetName='Prepare')]
    [String] $AdminUserName,

    # The admin password is in base64 string
    [Parameter(Mandatory=$true, ParameterSetName='Prepare')]
    [String] $AdminBase64Password,

    [Parameter(Mandatory=$true, ParameterSetName='Prepare')]
    [String] $PublicDnsName,

    [Parameter(Mandatory=$false, ParameterSetName='Prepare')]
    [String] $SubscriptionId,

    [Parameter(Mandatory=$false, ParameterSetName='Prepare')]
    [String] $VNet,

    [Parameter(Mandatory=$false, ParameterSetName='Prepare')]
    [String] $Subnet,

    [Parameter(Mandatory=$false, ParameterSetName='Prepare')]
    [String] $Location,

    [Parameter(Mandatory=$false, ParameterSetName='Prepare')]
    [String] $ResourceGroup="",

    [Parameter(Mandatory=$false, ParameterSetName='Prepare')]
    [String] $AzureStorageConnStr="",

    # The PostConfig script url and arguments in base64
    [Parameter(Mandatory=$false, ParameterSetName='Prepare')]
    [String] $PostConfigScript="",

    [Parameter(Mandatory=$false, ParameterSetName='Prepare')]
    [String] $CNSize="",

    [Parameter(Mandatory=$false, ParameterSetName='Prepare')]
    [Switch] $UnsecureDNSUpdate,

    [Parameter(Mandatory=$true, ParameterSetName='NodeState')]
    [switch] $NodeStateCheck
)

. "$PSScriptRoot\HpcPrepareUtil.ps1"


function PrepareHeadNode
{
    param
    (
    [Parameter(Mandatory=$true)]
    [String] $DomainFQDN,

    [Parameter(Mandatory=$true)]
    [String] $PublicDnsName,
        
    [Parameter(Mandatory=$true)]
    [String] $AdminUserName,

    [Parameter(Mandatory=$true)]
    [String] $AdminBase64Password,

    [Parameter(Mandatory=$false)]
    [String] $AzureStorageConnStr="",

    [Parameter(Mandatory=$false)]
    [String] $PostConfigScript="",

    [Parameter(Mandatory=$false)]
    [String] $CNSize="",

    [Parameter(Mandatory=$false)]
    [Switch] $UnsecureDNSUpdate
    )

    Import-Module ScheduledTasks

    $AdminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($AdminBase64Password))
    $domainNetBios = $DomainFQDN.Split('.')[0].ToUpper()
    $domainUserCred = New-Object -TypeName System.Management.Automation.PSCredential `
            -ArgumentList @("$domainNetBios\$AdminUserName", (ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force))

    # 0 for Standalone Workstation, 1 for Member Workstation, 2 for Standalone Server, 3 for Member Server, 4 for Backup Domain Controller, 5 for Primary Domain Controller
    $domainRole = (Get-WmiObject Win32_ComputerSystem).DomainRole
    TraceInfo "Domain role $domainRole"
    if($domainRole -lt 3)
    {
        # restart HN
        TraceInfo 'This machine is not domain joined'
        throw "This machine is not domain joined"
    }
    else
    {
        $job = Start-Job -ScriptBlock {
            param($scriptPath, $domainUserCred, $AzureStorageConnStr, $PublicDnsName, $PostConfigScript, $CNSize)

            . "$scriptPath\HpcPrepareUtil.ps1"
            TraceInfo 'register HPC Head Node Preparation Task'
            # prepare headnode
            $dbArgs = '-DBServerInstance .\COMPUTECLUSTER'
            $HNPreparePsFile = "$scriptPath\HPCHNPrepare.ps1"
            $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-ExecutionPolicy Unrestricted -Command `"& '$HNPreparePsFile' $dbArgs`""
            Register-ScheduledTask -TaskName 'HPCPrepare' -Action $action -User $domainUserCred.UserName -Password $domainUserCred.GetNetworkCredential().Password -RunLevel Highest *>$script:PrepareNodeLogFile
            if(-not $?)
            {
                TraceInfo 'Failed to schedule HPC Head Node Preparation Task'
                throw
            }

            TraceInfo 'HPC Head Node Preparation Task scheduled'
            Start-ScheduledTask -TaskName 'HPCPrepare'
            TraceInfo 'Running HPC Head Node Preparation Task'
            Start-Sleep -Milliseconds 500
            $taskSucceeded = $false
            do
            {
                $taskState = (Get-ScheduledTask -TaskName 'HPCPrepare').State
                if($taskState -eq 'Ready')
                {
                    $taskInfo = Get-ScheduledTaskInfo -TaskName 'HPCPrepare'
                    if($taskInfo.LastRunTime -eq $null)
                    {
                        Start-ScheduledTask -TaskName 'HPCPrepare'
                    }
                    else
                    {
                        if($taskInfo.LastTaskResult -eq 0)
                        {
                            $taskSucceeded = $true
                            break
                        }
                        else
                        {
                            TraceInfo ('The scheduled task for HPC Head Node Preparation failed:' + $taskInfo.LastTaskResult)
                            break
                        }
                    }
                }
                elseif($taskState -ne 'Queued' -and $taskState -ne 'Running')
                {
                    TraceInfo "The scheduled task for HPC Head Node Preparation entered into unexpected state: $taskState"
                    break
                }

                Start-Sleep -Seconds 2        
            } while ($true)

            if($taskSucceeded)
            {
                TraceInfo 'Checking the Head Node Services status ...'
                #$HNServiceList = @("HpcSdm", "HpcManagement", "HpcReporting", "HpcMonitoringClient", "HpcNodeManager", "msmpi", "HpcBroker", `
                #            "HpcDiagnostics", "HpcScheduler", "HpcMonitoringServer", "HpcSession", "HpcSoaDiagMon")
                $HNServiceList = @('HpcSdm', 'HpcManagement', 'HpcNodeManager', 'msmpi', 'HpcBroker', 'HpcScheduler', 'HpcSession')
                foreach($svcname in $HNServiceList)
                {
                    $service = Get-Service -Name $svcname -ErrorAction SilentlyContinue
                    if($service -eq $null)
                    {
                        TraceInfo "Service $svcname not found"
                        $taskSucceeded = $false
                    }
                    elseif($service.Status -eq 'Running')
                    {
                        TraceInfo "Service $svcname is running"
                    }
                    else
                    {
                        TraceInfo "Service $svcname is in $($service.Status) status"
                        $taskSucceeded = $false
                    }
                }
            }
            
            "Done" | Out-File "$env:windir\Temp\HPCPackHeadNodePrepared"
            Unregister-ScheduledTask -TaskName 'HPCPrepare' -Confirm:$false    

            if($taskSucceeded)
            {
                TraceInfo 'Succeeded to prepare HPC Head Node'
                # HPC to do list
                Add-PSSnapin Microsoft.HPC
                # setting network topology to 5 (enterprise)
                TraceInfo 'Setting HPC cluster network topologogy...'
                $nics = @(Get-WmiObject win32_networkadapterconfiguration -filter "IPEnabled='true' AND DHCPEnabled='true'")
                if ($nics.Count -ne 1)
                {
                    throw "Cannot find a suitable network adapter for enterprise topology"
                }
                $startTime = Get-Date
                while($true)
                {
                    Set-HpcNetwork -Topology 'Enterprise' -Enterprise $nics.Description -EnterpriseFirewall $true -ErrorAction SilentlyContinue 
                    $topo = Get-HpcNetworkTopology -ErrorAction SilentlyContinue
                    if ([String]::IsNullOrWhiteSpace($topo))
                    {
                        TraceInfo "Failed to set Hpc network topology, maybe the head node is still on initialization, retry after 10 seconds"
                        Start-Sleep -Seconds 10
                    }
                    else
                    {
                        TraceInfo "Network topology is set to $topo"
                        break;
                    }
                }

                # Set installation credentials
                Set-HpcClusterProperty -InstallCredential $domainUserCred
                $hpccred = Get-HpcClusterProperty -InstallCredential
                TraceInfo ('Installation Credentials set to ' + $hpccred.Value)

	            # set node naming series
                $nodenaming = 'AzureVMCN-%0000%'
                ExecuteCommandWithRetry -Command "Set-HpcClusterProperty -NodeNamingSeries $nodenaming"
                TraceInfo "Node naming series set to $nodenaming"
        
                # Create a default compute node template
                New-HpcNodeTemplate -Name 'Default ComputeNode Template' -Description 'This is the default compute node template' -ErrorAction SilentlyContinue
                TraceInfo "'Default ComputeNode Template' created"

                # Disable the ComputeNode role for head node.
                Set-HpcNode -Name $env:COMPUTERNAME -Role BrokerNode
                TraceInfo "Disabled ComputeNode role for head node"

                #set azure stroage connection string
                if(-not [string]::IsNullOrEmpty($AzureStorageConnStr))
                {
                    Set-HpcClusterProperty -AzureStorageConnectionString $AzureStorageConnStr
                    TraceInfo "Azure storage connection string configured"
                }

                $hpcBinPath = [System.IO.Path]::Combine($env:CCP_HOME, 'Bin')
                $restWebCert = Get-ChildItem -Path Cert:\LocalMachine\My | ?{($_.Subject -eq "CN=$PublicDnsName") -and $_.HasPrivateKey} | select -First(1)
                if($null -eq $restWebCert)
                {
                    TraceInfo "Generating a self-signed certificate(CN=$PublicDnsName) for the HPC web service ..."
                    $thumbprint = . $hpcBinPath\New-HpcCert.ps1 -MachineName $PublicDnsName -SelfSigned
                    TraceInfo "A self-signed certificate $thumbprint was created and installed"
                }
                else
                {
                    TraceInfo "Use the existing certificate $thumbprint (CN=$PublicDnsName) for the HPC web service."
                    $thumbprint = $restWebCert.Thumbprint
                }
        
                TraceInfo 'Enabling HPC Pack web portal ...'
                . $hpcBinPath\Set-HPCWebComponents.ps1 -Service Portal -enable -Certificate $thumbprint | Out-Null
                TraceInfo 'HPC Pack web portal enabled.'

                TraceInfo 'Starting HPC web service ...'
                Set-Service -Name 'HpcWebService' -StartupType Automatic | Out-Null
                Start-Service -Name 'HpcWebService' | Out-Null
                TraceInfo 'HPC web service started.'

                TraceInfo 'Enabling HPC Pack REST API ...'
                . $hpcBinPath\Set-HPCWebComponents.ps1 -Service REST -enable -Certificate $thumbprint | Out-Null
                TraceInfo 'HPC Pack REST API enabled.'

                TraceInfo 'Restarting HPCScheduler service ...'
                Restart-Service -Name 'HpcScheduler' -Force | Out-Null
                TraceInfo 'HPCScheduler service restarted.'

                # If the VMSize of the compute nodes is A8/A9, set the MPI net mask.
                if($CNSize -match "(A8|A9)$")
                {
                    $mpiNetMask = "172.16.0.0/255.255.0.0"
                    ## Wait for the completion of the "Updating cluster configuration" operation after setting network topology,
                    ## because in the operation, the CCP_MPI_NETMASK may be reset.
                    $waitLoop = 0
                    while ($null -eq (Get-HpcOperation -StartTime $startTime -State Committed | ?{$_.Name -eq "Updating cluster configuration"}))
                    {
                        if($waitLoop++ -ge 10)
                        {
                            break
                        }

                        Start-Sleep -Seconds 10
                    }

                    Set-HpcClusterProperty -Environment "CCP_MPI_NETMASK=$mpiNetMask"  | Out-Null
                    TraceInfo "Set cluster environment CCP_MPI_NETMASK to $mpiNetMask"
                }

                # register scheduler task to bring node online
                $task = Get-ScheduledTask -TaskName 'HpcNodeOnlineCheck' -ErrorAction SilentlyContinue
                if($null -eq $task)
                {
                    TraceInfo 'Start to register HpcNodeOnlineCheck Task'
                    $HpcNodeOnlineCheckFile = "$scriptPath\PrepareHN.ps1"
                    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-ExecutionPolicy Unrestricted -Command `"& '$HpcNodeOnlineCheckFile' -NodeStateCheck`""
                    $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 1) -At (get-date) -RepetitionDuration (New-TimeSpan -Minutes 90) -Once
                    Register-ScheduledTask -TaskName 'HpcNodeOnlineCheck' -Action $action -Trigger $trigger -User $domainUserCred.UserName -Password $domainUserCred.GetNetworkCredential().Password -RunLevel Highest | Out-Null
                    TraceInfo 'Finish to register task HpcNodeOnlineCheck'
                    if(-not $?)
                    {
                        TraceInfo 'Failed to schedule HpcNodeOnlineCheck Task'
                    }
                }
                else
                {
                    TraceInfo 'Task HpcNodeOnlineCheck already exists'
                }

                if(-not [String]::IsNullOrWhiteSpace($PostConfigScript))
                {
                    $PostConfigScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PostConfigScript))
                    $PostConfigScript = $PostConfigScript.Trim()
                    $firstSpace = $PostConfigScript.IndexOf(' ')
                    if($firstSpace -gt 0)
                    {
                        $scriptUrl = $PostConfigScript.Substring(0, $firstSpace)
                        $scriptArgs = $PostConfigScript.Substring($firstSpace + 1).Trim()
                    }
                    else
                    {
                        $scriptUrl = $PostConfigScript
                        $scriptArgs = ""
                    }

                    if(-not [system.uri]::IsWellFormedUriString($scriptUrl,[System.UriKind]::Absolute) -or $scriptUrl -notmatch '.ps1$')
                    {
                        TraceInfo "Invalid url or not PowerShell script: $scriptUrl"
                    }
                    else
                    {
                        $scriptFileName = $($scriptUrl -split '/')[-1]
                        $scriptFilePath = "$env:windir\Temp\$scriptFileName"

                        $downloader = New-Object System.Net.WebClient
                        $downloadRetry = 0
                        $downloaded = $false
                        while($true)
                        {
                            try
                            {
                                $downloader.DownloadFile($scriptUrl, $scriptFilePath)
                                $downloaded = $true
                                break
                            }
                            catch
                            {
                                if($downloadRetry -lt 10)
                                {
                                    TraceInfo ("Failed to download $scriptUrl, retry after 20 seconds:" + $_)
                                    Clear-DnsClientCache
                                    Start-Sleep -Seconds 20
                                    $downloadRetry++
                                }
                                else
                                {
                                    TraceInfo "Failed to download $scriptUrl after 10 retries"
                                }
                            }
                        }

                        if($downloaded)
                        {
                            TraceInfo "Start to run post config script: $scriptFilePath $scriptArgs."
                            $postScriptErrFile = "$env:windir\Temp\PostConfigScript.err"
                            $postScriptOutFile = "$env:windir\Temp\PostConfigScript.out"
                            Start-Process -Credential $domainUserCred -FilePath "PowerShell.exe" -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Unrestricted -File $scriptFilePath $scriptArgs" -NoNewWindow -RedirectStandardError $postScriptErrFile -RedirectStandardOutput $postScriptOutFile
                            if(-not $?)
                            {
                                TraceInfo ($Error[0] | Out-String)
                            }
                        }
                    }
                }
                else
                {
                    TraceInfo "PostConfigScript is empty, ignore it!"
                }                
            }
            else
            {
                TraceInfo 'Failed to prepare HPC Head Node'
                if(Test-Path -Path "$env:windir\Temp\HPCHeadNodePrepare.log" -PathType Leaf)
                {
                    TraceInfo 'The Head Node Preparation Logs as below:'
                    Get-Content -Path "$env:windir\Temp\HPCHeadNodePrepare.log" | Write-Verbose -Verbose
                }

                throw "Failed to prepare HPC Head Node"
            }
        } -ArgumentList $PSScriptRoot,$domainUserCred,$AzureStorageConnStr,$PublicDnsName,$PostConfigScript,$CNSize

        if($domainRole -eq 5)
        {
            if($null -ne (Get-DnsServerForwarder).IPAddress)
            {
                foreach($fwdIP in @((Get-DnsServerForwarder).IPAddress))
                {
                    if(($fwdIP -eq "fec0:0:0:ffff::1") -or ($fwdIP -eq "fec0:0:0:ffff::2") -or ($fwdIP -eq "fec0:0:0:ffff::3"))
                    {
                        TraceInfo "Removing DNS forwarder from the domain controller: $fwdIP"
                        Remove-DnsServerForwarder -IPAddress $fwdIP -Force
                    }
                }
            }

            if($UnsecureDNSUpdate.IsPresent)
            {
                TraceInfo "Waiting for default zone directory partitions ready"
                $retry = 0
                while ($true)
                {
                    try
                    {
                        $ddzState = (Get-DnsServerDirectoryPartition -Name "DomainDnsZones.$DomainFQDN").State
                        $fdzState = (Get-DnsServerDirectoryPartition -Name "ForestDnsZones.$DomainFQDN").State
                        if (0 -eq $ddzState -and 0 -eq $fdzState)
                        {
                            TraceInfo "Default zone directory partitions ready"
                            break
                        }

                        TraceInfo "Default zone directory partitions are not ready. DomainDnsZones: $ddzState ForestDnsZones: $fdzState"
                    }
                    catch
                    {
                        TraceInfo "Exception while getting zone directory partitions state: $($_ | Out-String)"
                    }
                    if ($retry++ -lt 60)
                    {
                        TraceInfo "Retry after 10 seconds"
                        Start-Sleep -Seconds 10
                    }
                    else
                    {
                        throw "Default zone directory partitions not ready after 20 retries"
                    }
                }

                try
                {
                    Set-DnsServerPrimaryZone -Name $DomainFQDN -DynamicUpdate NonsecureAndSecure -ErrorAction Stop
                    TraceInfo "Updated DNS DynamicUpdate to NonsecureAndSecure"
                }
                catch
                {
                    TraceInfo "Failed to update DNS DynamicUpdate to NonsecureAndSecure: $_"
                }
            }
        }

        Wait-Job $job
        TraceInfo 'Prepare head node job completed'
        TraceInfo "mainjobstate: $($job.JobStateInfo | out-string)"
        TraceInfo "output: $($job.ChildJobs[0].Output | out-string)"
        TraceInfo "jobstate: $($job.ChildJobs[0].JobStateInfo | fl | Out-String)"

        TraceInfo $job.
        Receive-Job $job -Verbose
    }
}

function NodeStateCheck
{
    Add-PSSnapin Microsoft.HPC

    $datetimestr = (Get-Date).ToString('yyyyMMdd')
    $script:PrepareNodeLogFile = "$env:windir\Temp\HpcNodeCheckLog-$datetimestr.txt"

    $offlineNodes = @()
    $offlineNodes += Get-HpcNode -State Offline -ErrorAction SilentlyContinue
    if($offlineNodes.Count -gt 0)
    {
        TraceInfo 'Start to bring nodes online'
        $result = @()
        $result += Set-HpcNodeState -State online -Node $offlineNodes
        PrintNodes $result
    }
}

Set-StrictMode -Version 3
if ($PsCmdlet.ParameterSetName -eq 'Prepare')
{
    if(Test-Path -Path "$env:windir\Temp\HPCPackHeadNodePrepared")
    {
        TraceInfo 'This head node was already prepared.'
        return
    }

    $prepareTask = Get-ScheduledTask -TaskName 'HPCPrepare' -ErrorAction SilentlyContinue
    if($null -ne $prepareTask)
    {
        TraceInfo 'This head node is on preparing'
        return
    }

    if(-not [string]::IsNullOrEmpty($SubscriptionId))
    {
        New-Item -Path HKLM:\SOFTWARE\Microsoft\HPC -Name IaaSInfo -Force | Out-Null
        Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\HPC\IaaSInfo -Name SubscriptionId -Value $SubscriptionId
        $deployId = "00000000" + [System.Guid]::NewGuid().ToString().Substring(8)
        Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\HPC\IaaSInfo -Name DeploymentId -Value $deployId
        Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\HPC\IaaSInfo -Name VNet -Value $VNet
        Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\HPC\IaaSInfo -Name Subnet -Value $Subnet
        Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\HPC\IaaSInfo -Name AffinityGroup -Value ""
        Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\HPC\IaaSInfo -Name Location -Value $Location
        if(-not [string]::IsNullOrEmpty($ResourceGroup))
        {
            Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\HPC\IaaSInfo -Name ResourceGroup -Value $ResourceGroup
        }
        TraceInfo "The information needed for in-box management scripts succcessfully configured."
    }

    TraceInfo "PrepareHeadNode -DomainFQDN $DomainFQDN -PublicDnsName $PublicDnsName -AdminUserName $AdminUserName -CNSize $CNSize -UnsecureDNSUpdate:$UnsecureDNSUpdate -PostConfigScript $PostConfigScript"
    PrepareHeadNode -DomainFQDN $DomainFQDN -PublicDnsName $PublicDnsName -AdminUserName $AdminUserName -AdminBase64Password $AdminBase64Password `
        -PostConfigScript $PostConfigScript -AzureStorageConnStr $AzureStorageConnStr -UnsecureDNSUpdate:$UnsecureDNSUpdate -CNSize $CNSize
}
else
{
    NodeStateCheck
}