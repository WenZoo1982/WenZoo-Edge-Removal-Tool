#requires -Version 5.1
<#
WenZoo-Edge-Removal-Tool.ps1
Removes the traditional desktop Microsoft Edge browser, while preserving the
Microsoft Edge WebView2 Runtime installation directory and product registration.
A pre-removal backup is mandatory before any changes. This script is best-effort:
Windows shell pins and OS-managed components vary by Windows 11 build.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'This tool only runs on Windows.' -ForegroundColor Red
    exit 1
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Administrator permission is required. Requesting elevation...' -ForegroundColor Yellow
    $launchArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath 'powershell.exe' -ArgumentList $launchArgs -Verb RunAs
    exit
}

$script:ToolRoot = Join-Path $env:ProgramData 'WenZoo\EdgeRemovalTool'
$script:BackupRoot = Join-Path $script:ToolRoot 'Backups'
$script:LogRoot = Join-Path $script:ToolRoot 'Logs'
New-Item -ItemType Directory -Path $script:BackupRoot, $script:LogRoot -Force | Out-Null
$script:LogPath = Join-Path $script:LogRoot ("WenZoo-EdgeRemoval-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))


function Get-UserProfiles {
    try {
        Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object { $_.LocalPath -and -not $_.Special -and (Test-Path -LiteralPath $_.LocalPath) }
    } catch {
        Get-ChildItem -LiteralPath $env:SystemDrive\Users -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ LocalPath = $_.FullName } }
    }
}

function Add-UniquePath {
    param([System.Collections.Generic.List[string]]$List, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $List.Contains($full)) { $List.Add($full) }
}

function Get-EdgeFileTargets {
    $paths = New-Object 'System.Collections.Generic.List[string]'
    Add-UniquePath $paths (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge')
    Add-UniquePath $paths (Join-Path $env:ProgramFiles 'Microsoft\Edge')
    Add-UniquePath $paths (Join-Path $env:ProgramFiles 'Microsoft\EdgeCore')
    if (${env:ProgramFiles(x86)}) { Add-UniquePath $paths (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeCore') }
    foreach ($profile in (Get-UserProfiles)) {
        Add-UniquePath $paths (Join-Path $profile.LocalPath 'AppData\Local\Microsoft\Edge')
        if (Test-Path -LiteralPath (Join-Path $profile.LocalPath 'AppData\Local\Microsoft\EdgeCore')) {
            Add-UniquePath $paths (Join-Path $profile.LocalPath 'AppData\Local\Microsoft\EdgeCore')
        }
    }
    # Do not add Microsoft\EdgeWebView or Microsoft\EdgeUpdate directories here.
    return @($paths | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-EdgeShortcutTargets {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    Add-UniquePath $roots ([Environment]::GetFolderPath('CommonDesktopDirectory'))
    Add-UniquePath $roots ([Environment]::GetFolderPath('CommonStartMenu'))
    foreach ($profile in (Get-UserProfiles)) {
        Add-UniquePath $roots (Join-Path $profile.LocalPath 'Desktop')
        Add-UniquePath $roots (Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu')
        Add-UniquePath $roots (Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
        Add-UniquePath $roots (Join-Path $profile.LocalPath 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\StartMenu')
    }
    $found = New-Object 'System.Collections.Generic.List[string]'
    $wsh = $null
    try { $wsh = New-Object -ComObject WScript.Shell } catch { Write-Log 'Could not initialize shortcut inspection COM object.' 'WARN' }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $shortcut = $_
            $isEdge = ($shortcut.BaseName -match '(?i)(^|\s)Microsoft Edge(\s|$)|^Edge$')
            if ($wsh) {
                try {
                    $lnk = $wsh.CreateShortcut($shortcut.FullName)
                    if ($lnk.TargetPath -and ([IO.Path]::GetFileName($lnk.TargetPath) -ieq 'msedge.exe')) { $isEdge = $true }
                } catch { }
            }
            if ($isEdge -and -not $found.Contains($shortcut.FullName)) { $found.Add($shortcut.FullName) }
        }
    }
    if ($wsh) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) }
    return @($found)
}

function Get-RegistryTargets {
    $results = New-Object 'System.Collections.Generic.List[string]'
    $known = @(
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )
    foreach ($k in $known) {
        if (Test-NativeRegistryKey $k) { [void]$results.Add($k) }
    }
    $uninstallRoots = @(
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        $psRoot = ConvertTo-RegistryProviderPath $root
        if (-not (Test-Path -LiteralPath $psRoot)) { continue }
        Get-ChildItem -LiteralPath $psRoot -ErrorAction SilentlyContinue | ForEach-Object {
            try { $displayName = (Get-ItemProperty -LiteralPath $_.PSPath -Name DisplayName -ErrorAction Stop).DisplayName } catch { $displayName = '' }
            if ($displayName -and $displayName.Trim() -ieq 'Microsoft Edge') { [void]$results.Add($root + '\' + $_.PSChildName) }
        }
    }
    # Remove only Edge's named updater product registration; never the shared updater root or WebView2 product.
    $clientRoots = @('HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients', 'HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients')
    foreach ($root in $clientRoots) {
        $psRoot = ConvertTo-RegistryProviderPath $root
        if (-not (Test-Path -LiteralPath $psRoot)) { continue }
        Get-ChildItem -LiteralPath $psRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $productId = $_.PSChildName
            try { $productName = (Get-ItemProperty -LiteralPath $_.PSPath -Name name -ErrorAction Stop).name } catch { $productName = '' }
            if ($productName -and $productName.Trim() -ieq 'Microsoft Edge') {
                [void]$results.Add($root + '\' + $productId)
                $stateRoot = $root -replace '\\Clients$', '\ClientState'
                $stateKey = $stateRoot + '\' + $productId
                if (Test-NativeRegistryKey $stateKey) { [void]$results.Add($stateKey) }
            }
        }
    }
    return @($results | Select-Object -Unique)
}

function ConvertTo-RegistryProviderPath {
    param([string]$NativePath)
    if ($NativePath -like 'HKLM\*') { return 'Registry::HKEY_LOCAL_MACHINE\' + $NativePath.Substring(5) }
    if ($NativePath -like 'HKCU\*') { return 'Registry::HKEY_CURRENT_USER\' + $NativePath.Substring(5) }
    if ($NativePath -like 'HKU\*') { return 'Registry::HKEY_USERS\' + $NativePath.Substring(4) }
    return $NativePath
}
function Test-NativeRegistryKey {
    param([string]$NativePath)
    return (Test-Path -LiteralPath (ConvertTo-RegistryProviderPath $NativePath))
}

function Get-RegistrySnapshotTargets {
    # These keys are snapshotted for restoration only; they are NOT removed by cleanup.
    @(
        'HKLM\SOFTWARE\Microsoft\Edge',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Edge',
        'HKCU\SOFTWARE\Microsoft\Edge',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount'
    )
}

function Get-EdgeServices {
    @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^(edgeupdate|edgeupdatem|MicrosoftEdgeElevationService)$' -or
        ($_.DisplayName -match '(?i)Microsoft Edge Update|Microsoft Edge Elevation')
    })
}
function Get-EdgeTasks {
    $all = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    $all | Where-Object {
        $_.TaskName -match '(?i)MicrosoftEdgeUpdate|EdgeUpdate' -or
        $_.TaskPath -match '(?i)\\Microsoft\\EdgeUpdate\\' -or
        (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ') -match '(?i)Microsoft\\EdgeUpdate|edgeupdate'
    }
}

function Invoke-Robocopy {
    param([string]$Source, [string]$Destination, [switch]$Mirror)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $mode = if ($Mirror) { '/MIR' } else { '/E' }
    & "$env:SystemRoot\System32\robocopy.exe" $Source $Destination $mode '/COPYALL' '/DCOPY:DAT' '/R:1' '/W:1' '/XJ' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { throw "Robocopy failed (exit code $code): $Source" }
}

function Save-BackupPath {
    param([string]$OriginalPath, [string]$PayloadRoot, [int]$Index)
    $dest = Join-Path $PayloadRoot ('Item-{0:D4}' -f $Index)
    if (Test-Path -LiteralPath $OriginalPath -PathType Container) {
        Invoke-Robocopy -Source $OriginalPath -Destination $dest
        return [pscustomobject]@{ OriginalPath = $OriginalPath; BackupPath = $dest; IsDirectory = $true }
    } else {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -LiteralPath $OriginalPath -Destination (Join-Path $dest (Split-Path $OriginalPath -Leaf)) -Force -ErrorAction Stop
        return [pscustomobject]@{ OriginalPath = $OriginalPath; BackupPath = (Join-Path $dest (Split-Path $OriginalPath -Leaf)); IsDirectory = $false }
    }
}

function New-PreRemovalBackup {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $script:BackupRoot $stamp
    $payload = Join-Path $backupDir 'Payload'
    $regDir = Join-Path $backupDir 'Registry'
    $taskDir = Join-Path $backupDir 'Tasks'
    $snapshotDir = Join-Path $backupDir 'RegistrySnapshots'
    New-Item -ItemType Directory -Path $payload, $regDir, $taskDir, $snapshotDir -Force | Out-Null
    Write-Log "Creating mandatory pre-removal backup: $backupDir"

    $manifest = [ordered]@{
        SchemaVersion = 1
        CreatedAt = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        FileEntries = @()
        RegistryEntries = @()
        RegistrySnapshots = @()
        Services = @()
        Tasks = @()
        BackupWarnings = @()
        RemovalResults = @()
    }
    $fileTargets = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in (Get-EdgeFileTargets)) { Add-UniquePath $fileTargets $p }
    foreach ($p in (Get-EdgeShortcutTargets)) { if (Test-Path -LiteralPath $p -PathType Leaf) { Add-UniquePath $fileTargets $p } }
    $idx = 0
    foreach ($p in $fileTargets) {
        $idx++
        try {
            $entry = Save-BackupPath -OriginalPath $p -PayloadRoot $payload -Index $idx
            $manifest.FileEntries += $entry
            Write-Log "Backed up: $p" 'OK'
        } catch {
            $manifest.BackupWarnings += "File backup failed: $p -- $($_.Exception.Message)"
            Write-Log "Backup failed for '$p': $($_.Exception.Message)" 'ERROR'
        }
    }

    $regIndex = 0
    foreach ($key in (Get-RegistryTargets)) {
        $regIndex++
        $regFile = Join-Path $regDir ('Registry-{0:D4}.reg' -f $regIndex)
        & reg.exe export $key $regFile /y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $regFile)) {
            $manifest.RegistryEntries += [pscustomobject]@{ NativePath = $key; BackupFile = $regFile }
            Write-Log "Backed up registry key: $key" 'OK'
        } else {
            $manifest.BackupWarnings += "Registry backup failed: $key"
            Write-Log "Could not export registry key: $key" 'ERROR'
        }
    }

    $snapshotIndex = 0
    foreach ($key in (Get-RegistrySnapshotTargets)) {
        if (-not (Test-NativeRegistryKey $key)) { continue }
        $snapshotIndex++
        $regFile = Join-Path $snapshotDir ('Snapshot-{0:D4}.reg' -f $snapshotIndex)
        & reg.exe export $key $regFile /y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $regFile)) {
            $manifest.RegistrySnapshots += [pscustomobject]@{ NativePath = $key; BackupFile = $regFile }
            Write-Log "Snapshotted registry state for restoration: $key" 'OK'
        } else {
            $manifest.BackupWarnings += "Registry snapshot failed: $key"
            Write-Log "Could not snapshot registry key: $key" 'ERROR'
        }
    }

    foreach ($svc in (Get-EdgeServices)) {
        $manifest.Services += [pscustomobject]@{
            Name = $svc.Name; DisplayName = $svc.DisplayName; StartMode = $svc.StartMode
            WasRunning = ($svc.State -eq 'Running'); State = $svc.State
        }
    }

    foreach ($task in (Get-EdgeTasks)) {
        try {
            $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            $fileName = ('Task-{0:D4}.xml' -f ($manifest.Tasks.Count + 1))
            $xmlPath = Join-Path $taskDir $fileName
            Set-Content -LiteralPath $xmlPath -Value $xml -Encoding Unicode
            $manifest.Tasks += [pscustomobject]@{
                TaskName = $task.TaskName; TaskPath = $task.TaskPath
                WasEnabled = [bool]$task.Settings.Enabled; BackupFile = $xmlPath
            }
        } catch {
            $manifest.BackupWarnings += "Scheduled task backup failed: $($task.TaskPath)$($task.TaskName) -- $($_.Exception.Message)"
            Write-Log "Could not back up scheduled task '$($task.TaskPath)$($task.TaskName)': $($_.Exception.Message)" 'ERROR'
        }
    }

    $manifestPath = Join-Path $backupDir 'manifest.json'
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if ($manifest.BackupWarnings.Count -gt 0) {
        Write-Log 'Backup is incomplete. No Edge cleanup will be attempted. Review the backup log and warnings.' 'ERROR'
        throw "Backup incomplete. Backup retained at: $backupDir"
    }
    Set-Content -LiteralPath (Join-Path $script:BackupRoot 'latest-backup.txt') -Value $backupDir -Encoding UTF8
    Write-Log 'Mandatory backup completed successfully.' 'OK'
    return $backupDir
}

function Invoke-UnpinAttempt {
    param([string]$ShortcutPath)
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path $ShortcutPath -Parent))
        if ($folder) {
            $item = $folder.ParseName((Split-Path $ShortcutPath -Leaf))
            if ($item) {
                foreach ($verb in $item.Verbs()) {
                    $name = ($verb.Name -replace '&','').Trim()
                    if ($name -match '(?i)unpin.*(taskbar|start)|取消固定|从.*固定') {
                        $verb.DoIt()
                        Write-Log "Requested shell unpin action '$name' for $ShortcutPath" 'INFO'
                    }
                }
            }
        }
        if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    } catch { Write-Log "Could not invoke unpin action for ${ShortcutPath}: $($_.Exception.Message)" 'WARN' }
}

function Invoke-PinAttempt {
    param([string]$ShortcutPath)
    if ($ShortcutPath -notmatch '(?i)User Pinned\\(?:TaskBar|StartMenu)') { return }
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path $ShortcutPath -Parent))
        if ($folder) {
            $item = $folder.ParseName((Split-Path $ShortcutPath -Leaf))
            if ($item) {
                foreach ($verb in $item.Verbs()) {
                    $name = ($verb.Name -replace '&','').Trim()
                    if ($name -match '(?i)pin.*(taskbar|start)|固定到任务栏|固定到.*开始') {
                        $verb.DoIt()
                        Write-Log "Requested shell pin action '$name' for $ShortcutPath" 'INFO'
                    }
                }
            }
        }
        if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    } catch { Write-Log "Could not restore pin state for ${ShortcutPath}: $($_.Exception.Message)" 'WARN' }
}

function Invoke-EdgeUninstallers {
    $edgeDirs = @(Get-EdgeFileTargets | Where-Object { $_ -match '(?i)\\Microsoft\\Edge$' })
    foreach ($dir in $edgeDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $setups = @(Get-ChildItem -LiteralPath $dir -Filter 'setup.exe' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '(?i)\\Application\\[^\\]+\\Installer\\setup\.exe$' } |
            Sort-Object FullName -Descending)
        foreach ($setup in $setups) {
            try {
                $args = @('--uninstall','--force-uninstall','--verbose-logging')
                if ($dir -like "$env:ProgramFiles*" -or $dir -like "${env:ProgramFiles(x86)}*") { $args += '--system-level' }
                Write-Log "Running Edge uninstaller: $($setup.FullName) $($args -join ' ')"
                $p = Start-Process -FilePath $setup.FullName -ArgumentList $args -Wait -PassThru -ErrorAction Stop
                Write-Log "Uninstaller exit code: $($p.ExitCode) for $($setup.FullName)" $(if ($p.ExitCode -eq 0) {'OK'} else {'WARN'})
            } catch { Write-Log "Edge uninstaller failed: $($_.Exception.Message)" 'WARN' }
        }
    }
}

function Remove-Edge {
    Write-Log 'Starting full Edge removal. WebView2 Runtime paths are excluded.'
    $backupDir = New-PreRemovalBackup
    $manifestPath = Join-Path $backupDir 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

    Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Log 'Stopped running msedge.exe processes.'

    foreach ($task in (Get-EdgeTasks)) {
        try {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Log "Removed Edge Update task: $($task.TaskPath)$($task.TaskName)" 'OK'
        } catch { Write-Log "Could not remove task '$($task.TaskPath)$($task.TaskName)': $($_.Exception.Message)" 'WARN' }
    }

    foreach ($svc in (Get-EdgeServices)) {
        try {
            if ($svc.State -eq 'Running') { Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue }
            Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
            Write-Log "Disabled Edge Update service: $($svc.Name)" 'OK'
        } catch { Write-Log "Could not disable service '$($svc.Name)': $($_.Exception.Message)" 'WARN' }
    }
    Invoke-EdgeUninstallers

    foreach ($p in (Get-EdgeShortcutTargets)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        Invoke-UnpinAttempt -ShortcutPath $p
        try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; Write-Log "Removed shortcut: $p" 'OK' }
        catch { Write-Log "Could not remove shortcut '$p': $($_.Exception.Message)" 'WARN' }
    }

    # Remove only Edge browser/profile directories. EdgeWebView and EdgeUpdate directories are intentionally excluded.
    foreach ($p in (Get-EdgeFileTargets)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if ($p -match '(?i)\\Microsoft\\EdgeWebView(\\|$)|\\Microsoft\\EdgeUpdate(\\|$)') {
            Write-Log "Protected shared/runtime directory: $p" 'WARN'; continue
        }
        try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop; Write-Log "Removed directory: $p" 'OK' }
        catch { Write-Log "Could not completely remove directory '$p': $($_.Exception.Message)" 'WARN' }
    }

    foreach ($key in (Get-RegistryTargets)) {
        try {
            $providerPath = ConvertTo-RegistryProviderPath $key
            if (Test-Path -LiteralPath $providerPath) {
                Remove-Item -LiteralPath $providerPath -Recurse -Force -ErrorAction Stop
                Write-Log "Removed browser registration: $key" 'OK'
            }
        } catch { Write-Log "Could not remove registry key '$key': $($_.Exception.Message)" 'WARN' }
    }

    $residuals = New-Object 'System.Collections.Generic.List[string]'
    $intentional = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in (Get-EdgeFileTargets)) { if (Test-Path -LiteralPath $p) { $residuals.Add("Directory remains: $p") } }
    foreach ($p in (Get-EdgeShortcutTargets)) { if (Test-Path -LiteralPath $p) { $residuals.Add("Shortcut remains: $p") } }
    foreach ($svc in (Get-EdgeServices)) {
        if ($svc.StartMode -ne 'Disabled') { $residuals.Add("Edge update service not disabled: $($svc.Name) ($($svc.StartMode))") }
        else { $intentional.Add("Edge update service remains registered but disabled: $($svc.Name)") }
    }
    foreach ($task in (Get-EdgeTasks)) { $residuals.Add("Edge Update task remains: $($task.TaskPath)$($task.TaskName)") }
    foreach ($key in (Get-RegistryTargets)) { if (Test-NativeRegistryKey $key) { $residuals.Add("Registry key remains: $key") } }
    $reportPath = Join-Path $backupDir 'removal-report.txt'
    $report = @(
        'WenZoo Edge Removal Tool - Removal Report',
        ('Date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('Computer: ' + $env:COMPUTERNAME),
        ('Backup: ' + $backupDir),
        '',
        'Notes:',
        '- WebView2 Runtime files and product registration are intentionally protected.',
        '- Shared Edge Update files may remain. Disabling Edge Update can also stop automatic updates for WebView2 Runtime, although the runtime files are preserved.',
        '- Windows 11 Start/taskbar pin databases and OS-managed packages may not be fully controllable on every build.',
        '- A clean result does not guarantee Windows Update will never reinstall Edge.',
        '',
        'Intentionally retained / disabled components:'
    )
    if ($intentional.Count -eq 0) { $report += 'None detected.' } else { $report += @($intentional) }
    $report += ''; $report += 'Residuals / exceptions:'
    if ($residuals.Count -eq 0) { $report += 'No targeted residuals detected by the checks in this script.' }
    else { $report += @($residuals) }
    Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8
    $manifest.RemovalResults = @($residuals)
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if ($residuals.Count -eq 0) { Write-Log "Cleanup finished; no targeted residuals detected. Report: $reportPath" 'OK' }
    else { Write-Log "Cleanup finished with $($residuals.Count) residual/exception item(s). Review: $reportPath" 'WARN' }
    Write-Log "Backup retained for restoration: $backupDir" 'OK'
    Read-Host 'Press Enter to return to the menu' | Out-Null
}

function Get-LatestBackupDirectory {
    $pointer = Join-Path $script:BackupRoot 'latest-backup.txt'
    if (Test-Path -LiteralPath $pointer) {
        $candidate = (Get-Content -LiteralPath $pointer -Raw -Encoding UTF8).Trim()
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'manifest.json'))) { return $candidate }
    }
    $latest = Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { return $latest.FullName }
    return $null
}

function Restore-PreRemovalState {
    $backupDir = Get-LatestBackupDirectory
    if (-not $backupDir) { Write-Log 'No valid backup found. Nothing to restore.' 'ERROR'; Read-Host 'Press Enter' | Out-Null; return }
    Write-Host "Backup selected: $backupDir" -ForegroundColor Cyan
    Write-Host 'Restoration may overwrite current files and restore Edge Update services/tasks to their recorded state.' -ForegroundColor Yellow
    $confirm = Read-Host 'Type RESTORE to continue'
    if ($confirm -cne 'RESTORE') { Write-Log 'Restore cancelled by user.' 'WARN'; return }
    $manifest = Get-Content -LiteralPath (Join-Path $backupDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach ($entry in @($manifest.FileEntries)) {
        try {
            if ($entry.IsDirectory) {
                Invoke-Robocopy -Source $entry.BackupPath -Destination $entry.OriginalPath -Mirror
            } else {
                $parent = Split-Path $entry.OriginalPath -Parent
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                Copy-Item -LiteralPath $entry.BackupPath -Destination $entry.OriginalPath -Force -ErrorAction Stop
            }
            Write-Log "Restored: $($entry.OriginalPath)" 'OK'
            if ($entry.OriginalPath -match '(?i)User Pinned\\(?:TaskBar|StartMenu)') { Invoke-PinAttempt -ShortcutPath $entry.OriginalPath }
        } catch { Write-Log "Could not restore '$($entry.OriginalPath)': $($_.Exception.Message)" 'ERROR' }
    }

    foreach ($entry in @($manifest.RegistryEntries)) {
        try {
            if (Test-Path -LiteralPath $entry.BackupFile) {
                & reg.exe import $entry.BackupFile 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "reg.exe import exit code $LASTEXITCODE" }
                Write-Log "Restored registry key: $($entry.NativePath)" 'OK'
            }
        } catch { Write-Log "Could not restore registry key '$($entry.NativePath)': $($_.Exception.Message)" 'ERROR' }
    }

    foreach ($entry in @($manifest.RegistrySnapshots)) {
        try {
            if (Test-Path -LiteralPath $entry.BackupFile) {
                & reg.exe import $entry.BackupFile 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "reg.exe import exit code $LASTEXITCODE" }
                Write-Log "Restored registry snapshot: $($entry.NativePath)" 'OK'
            }
        } catch { Write-Log "Could not restore registry snapshot '$($entry.NativePath)': $($_.Exception.Message)" 'ERROR' }
    }

    foreach ($svc in @($manifest.Services)) {
        try {
            $startup = switch -Regex ($svc.StartMode) { '^Auto' {'Automatic'} '^Manual$' {'Manual'} '^Disabled$' {'Disabled'} default {'Manual'} }
            if (Get-Service -Name $svc.Name -ErrorAction SilentlyContinue) {
                Set-Service -Name $svc.Name -StartupType $startup -ErrorAction Stop
                if ($svc.WasRunning) { Start-Service -Name $svc.Name -ErrorAction SilentlyContinue }
                else { Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue }
                Write-Log "Restored service state: $($svc.Name) ($startup)" 'OK'
            } else { Write-Log "Service not present after file/registry restore: $($svc.Name)" 'WARN' }
        } catch { Write-Log "Could not restore service '$($svc.Name)': $($_.Exception.Message)" 'ERROR' }
    }

    foreach ($task in @($manifest.Tasks)) {
        try {
            $xml = Get-Content -LiteralPath $task.BackupFile -Raw -Encoding Unicode -ErrorAction Stop
            Register-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Xml $xml -Force -ErrorAction Stop | Out-Null
            if ($task.WasEnabled) { Enable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null }
            else { Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null }
            Write-Log "Restored scheduled task: $($task.TaskPath)$($task.TaskName)" 'OK'
        } catch { Write-Log "Could not restore task '$($task.TaskPath)$($task.TaskName)': $($_.Exception.Message)" 'ERROR' }
    }

    Write-Log 'Restore operation completed. Review this log for failures, then verify Edge and WebView2 manually.' 'OK'
    Read-Host 'Press Enter to return to the menu' | Out-Null
}

function Remove-Backups {
    $dirs = @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue)
    if ($dirs.Count -eq 0) { Write-Log 'No backup directories found.'; Read-Host 'Press Enter' | Out-Null; return }
    Write-Host 'The following backup directories will be permanently deleted:' -ForegroundColor Yellow
    $dirs | ForEach-Object { Write-Host ('  ' + $_.FullName) }
    Write-Host 'This cannot be undone. Delete backups only after you no longer need restoration.' -ForegroundColor Red
    $confirm = Read-Host 'Type DELETE to delete ALL listed backups'
    if ($confirm -cne 'DELETE') { Write-Log 'Backup deletion cancelled.' 'WARN'; return }
    foreach ($dir in $dirs) {
        try { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop; Write-Log "Deleted backup: $($dir.FullName)" 'OK' }
        catch { Write-Log "Could not delete backup '$($dir.FullName)': $($_.Exception.Message)" 'ERROR' }
    }
    Remove-Item -LiteralPath (Join-Path $script:BackupRoot 'latest-backup.txt') -Force -ErrorAction SilentlyContinue
    Read-Host 'Press Enter to return to the menu' | Out-Null
}

while ($true) {
    Clear-Host
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ' WenZoo Edge Removal Tool' -ForegroundColor Cyan
    Write-Host ' Microsoft Edge Removal and Restore' -ForegroundColor Cyan
    Write-Host ' WebView2 Runtime Protection: Enabled' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '1. Completely Remove Edge (No Residuals)'
    Write-Host '2. Restore Pre-Removal State'
    Write-Host '3. Delete Backup'
    Write-Host '4. Exit'
    Write-Host ''
    $choice = Read-Host 'Select an option'
    switch ($choice) {
        '1' {
            Write-Host ''
            Write-Host 'WARNING: This stops/disables Edge Update, removes Edge files and browser data, and may be irreversible if the backup is damaged.' -ForegroundColor Red
            Write-Host 'WebView2 Runtime directories and product registrations are excluded. Disabling Edge Update can also stop WebView2 updates.' -ForegroundColor Yellow
            $confirm = Read-Host 'Type REMOVE to create a backup and proceed'
            if ($confirm -ceq 'REMOVE') {
                try { Remove-Edge } catch { Write-Log "Removal aborted: $($_.Exception.Message)" 'ERROR'; Read-Host 'Press Enter to return to the menu' | Out-Null }
            } else { Write-Log 'Removal cancelled by user.' 'WARN'; Start-Sleep -Seconds 1 }
        }
        '2' { Restore-PreRemovalState }
        '3' { Remove-Backups }
        '4' { Write-Log 'Exited by user.'; break }
        default { Write-Host 'Invalid selection.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
}
