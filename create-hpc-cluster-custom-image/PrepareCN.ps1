param
(
    [Parameter(Mandatory=$true)]
    [String] $DomainFQDN, 
    
    [Parameter(Mandatory=$true)]
    [String] $ClusterName,

    [Parameter(Mandatory=$true)]
    [String] $AdminUserName,

    [Parameter(Mandatory=$true)]
    [String] $AdminBase64Password,

    [Parameter(Mandatory=$false)]
    [String] $PostConfigScript=""
)

function TraceInfo($log)
{
    if ($script:LogFile -ne $null)
    {
        "$(Get-Date -format 'MM/dd/yyyy HH:mm:ss') $log" | Out-File -Confirm:$false -FilePath $script:LogFile -Append
    }    
}

function InstallComputeNode
{
    param($clustername)

    if(Test-Path -Path "C:\HPCPatches")
    {
        Remove-Item -Path "C:\HPCPatches" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }

    New-Item -ItemType directory -Path "C:\HPCPatches" -Force | Out-Null
    
    # 0 for Standalone Workstation, 1 for Member Workstation, 2 for Standalone Server, 3 for Member Server, 4 for Backup Domain Controller, 5 for Primary Domain Controller
    $domainRole = (Get-WmiObject Win32_ComputerSystem).DomainRole
    if($domainRole -lt 3)
    {
        throw "$nodetype $env:COMPUTERNAME is not domain joined"
    }
    
    # Test the connection to head node
    TraceInfo "Testing the connection to $clustername ..."
    $maxRetries = 50
    $retry = 0
    while($true)
    {
        # Flush the DNS cache in case the cached head node ip is wrong.
        # Do not use Clear-DnsClientCache because it is not supported in Windows Server 2008 R2
        Start-Process -FilePath ipconfig -ArgumentList "/flushdns" -Wait -NoNewWindow | Out-Null
        if(Test-Connection -ComputerName $clustername -Quiet)
        {
            TraceInfo "Head node $clustername is now reachable."
            break
        }
        else
        {
            if($retry -lt 20)
            {
                Start-Sleep -Seconds 20
                $retry++
            }
            else
            {
                throw "Head node $clustername is unreachable"
            }
        }
    }

    $retry = 0
    while($true)
    {
        if(Test-Path "\\$clustername\REMINST\setup.exe")
        {
            Copy-Item \\$clustername\REMINST\Patches\KB*.exe C:\HPCPatches -ErrorAction SilentlyContinue
            break
        }
        elseif($retry -lt 30)
        {
            $retry++
            Start-Sleep -Seconds 20
        }
        else
        {
            throw "\\$clustername\REMINST\setup.exe not available"
        }
    }
    
    # Install HPC compute node
    TraceInfo "Installing HPC Pack compute node from \\$clustername\REMINST"
    $pSetup = Start-Process -FilePath "\\$clustername\REMINST\setup.exe" -ArgumentList "-unattend -computenode:$clustername" -Wait -PassThru
    if(($pSetup.ExitCode -ne 0) -and ($pSetup.ExitCode -ne 3010))
    {
        throw "Failed to install compute node: $($pSetup.ExitCode)"
    }
    TraceInfo "Succeeded to install HPC Pack compute node."

    # Apply the patches if any
    $patchfiles = @(Get-ChildItem "C:\HPCPatches" -Filter "KB*.exe" | select -ExpandProperty FullName)
    if($patchfiles.Count -gt 0)
    {
        # sleep for 10 seconds before applying QFEs
        Start-Sleep -Seconds 10
        $patchTable = @{}
        foreach($pfile in $patchfiles)
        {
            $versionStr = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($pfile).ProductVersion
            $version = New-Object System.Version $versionStr
            $patchTable[$version] = $pfile
        }

        $versions = @($patchTable.Keys | Sort-Object)
        foreach($ver in $versions)
        {
            $pfile = $patchTable[$ver]
            TraceInfo "Applying QFE hotfix $pfile"
            $p = Start-Process -FilePath $pfile -ArgumentList "/unattend" -PassThru -Wait
            if(($p.ExitCode -ne 0) -and ($p.ExitCode -ne 3010))
            {
                throw "Failed to apply QFE hotfix $pfile : $($p.ExitCode)"
            }

            Start-Sleep -Seconds 10
        }
    }

    Remove-Item -Path "C:\HPCPatches" -Recurse -Force -ErrorAction SilentlyContinue
}

try
{
    Set-StrictMode -Version 3
}
catch
{
}

$postScriptConfigured = $false
# Do not use IsNullOrWhiteSpace because it is not supported in DotNetFx3.5
if(-not [String]::IsNullOrEmpty($PostConfigScript))
{
    $PostConfigScript = $PostConfigScript.Trim()
    if(-not [String]::IsNullOrEmpty($PostConfigScript))
    {
        $postScriptConfigured = $true
    }
}

$datetimestr = (Get-Date).ToString("yyyyMMddHHmmssfff")        
$script:LogFile = "$env:windir\Temp\HpcPrepareCNLog-$datetimestr.txt"

$AdminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($AdminBase64Password))
$domainNetBios = $DomainFQDN.Split(".")[0].ToUpper()
$domainUserCred = New-Object -TypeName System.Management.Automation.PSCredential `
        -ArgumentList @("$domainNetBios\$AdminUserName", (ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force))

$taskName = "HpcPrepareComputeNode"
# 0 for Standalone Workstation, 1 for Member Workstation, 2 for Standalone Server, 3 for Member Server, 4 for Backup Domain Controller, 5 for Primary Domain Controller
$domainRole = (Get-WmiObject Win32_ComputerSystem).DomainRole
TraceInfo "Domain role $domainRole"
if($domainRole -ne 3)
{
    TraceInfo "$env:COMPUTERNAME does not join the domain, start to join domain $DomainFQDN"
    # join the domain
    while($true)
    {
        try
        {
            Add-Computer -DomainName $DomainFQDN -Credential $domainUserCred -ErrorAction Stop
            TraceInfo "Joined to the domain $DomainFQDN."
            break
        }
        catch
        {
            # Flush the DNS cache in case there is wrong cache for $DomainFQDN.
            # Do not use Clear-DnsClientCache because it is not supported in Windows Server 2008 R2
            Start-Process -FilePath ipconfig -ArgumentList "/flushdns" -Wait -NoNewWindow | Out-Null
            TraceInfo "Join domain failed, will try after 5 seconds, $_"
            Start-Sleep -Seconds 5
        }
    }

    $hpcmgmt = Get-Service -Name HpcManagement -ErrorAction SilentlyContinue
    if($hpcmgmt -ne $null -and (-not $postScriptConfigured))
    {
        # If HPC Pack already installed, and no post script is configured, we just set the cluster name and reboot the computer.
        # No need to schedule task
        TraceInfo "HPC Pack already installed, start to set cluster name to $ClusterName"
        Set-HpcClusterName.ps1 -ClusterName $ClusterName
        TraceInfo "Finish to set cluster name"
    }
    else
    {
        # Because ScheduledTasks PowerShell module not available in Windows Server 2008 R2,
        # We use ComObject Schedule.Service to schedule task
        try
        {
            $schdService = new-object -ComObject "Schedule.Service"
            $schdService.Connect("localhost") | Out-Null
            $rootFolder = $schdService.GetFolder("\")
            $task = $rootFolder.GetTasks(0) | ?{$_.Name -eq $taskName}
            if($null -eq $task)
            {
                $taskDefinition = $schdService.NewTask(0)
                $action = $taskDefinition.Actions.Create(0)
                $action.Path = "PowerShell.exe"
                $CNPreparePsFile = $MyInvocation.MyCommand.Definition
                $taskArgs = "-DomainFQDN $DomainFQDN -ClusterName $ClusterName -AdminUserName $AdminUserName -AdminBase64Password $AdminBase64Password"
                if($postScriptConfigured)
                {
                    $taskArgs += " -PostConfigScript '$PostConfigScript'"
                }
                $action.Arguments = "-ExecutionPolicy Unrestricted -Command `"& '$CNPreparePsFile' $taskArgs`""
                # TASK_TRIGGER_BOOT = 8
                $trigger = $taskDefinition.Triggers.Create(8)

                $task = $rootFolder.RegisterTaskDefinition($taskName, $taskDefinition, 2, "system", $null, 5)
                TraceInfo "Register task $taskName"
            }
        }
        catch
        {
            throw "Failed to schedule task $taskName" 
        }
    }

    TraceInfo "Restart after 30 seconds"
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c shutdown /r /t 30"
}
else
{   
    $hpcmgmt = Get-Service -Name HpcManagement -ErrorAction SilentlyContinue
    if($hpcmgmt -ne $null)
    {
        TraceInfo "Start to set cluster name to $ClusterName"
        Set-HpcClusterName.ps1 -ClusterName $ClusterName
        TraceInfo "Finish to set cluster name"
    }
    else
    {
        TraceInfo "Start to install compute node"
        InstallComputeNode $ClusterName
        TraceInfo "Finish to install compute node"
    }

    if($postScriptConfigured)
    {
        $webclient = New-Object System.Net.WebClient
        $spaceIndex = $PostConfigScript.IndexOf(' ')
        if($spaceIndex -lt 0)
        {
            $scriptUrl = $PostConfigScript
            $scriptArgs = ""
        }
        else
        {
            $scriptUrl = $PostConfigScript.Substring(0, $spaceIndex)
            $scriptArgs = $PostConfigScript.Substring($spaceIndex+1)
        }

        $scriptName = $($scriptUrl -split '/')[-1]
        $scriptFile = "$env:windir\Temp\$scriptName"
        TraceInfo "download post config script from $scriptUrl"
        $webclient.DownloadFile($scriptUrl, $scriptFile)
        $scriptCommand = "$scriptFile $scriptArgs"
        TraceInfo "execute post config script: $scriptCommand"
        Invoke-Expression -Command $scriptCommand
        TraceInfo "finish to post config script"
    }
    else
    {
        TraceInfo "PostConfigScript is empty, ignore it!"
    }

    try
    {
        $schdService = new-object -ComObject "Schedule.Service"
        $schdService.Connect("localhost") | Out-Null
        $rootFolder = $schdService.GetFolder("\")
        $task = $rootFolder.GetTasks(0) | ?{$_.Name -eq $taskName}
        if($null -ne $task)
        {
            $rootFolder.DeleteTask($taskName,0)  | Out-Null
            TraceInfo "Removed scheduled task $taskName"
        }
    }
    catch
    {
        TraceInfo "Failed to remove scheduled task $taskName"
    }
}
