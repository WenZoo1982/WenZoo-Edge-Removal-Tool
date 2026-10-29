#requires -Version 5.1
<#
WenZoo-Edge-Removal-Tool.ps1
Version: 0.5.1
Removes the traditional desktop Microsoft Edge browser, while preserving the
Microsoft Edge WebView2 Runtime installation directory and product registration.
A pre-removal backup is mandatory before any changes. This script is best-effort:
Windows shell pins and OS-managed components vary by Windows 11 build.
The interface supports Simplified Chinese and English. Diagnostic log files remain English.
The tool runs in the current PowerShell host. Choosing Exit terminates that PowerShell process; run it only in a dedicated elevated PowerShell window with no other work to preserve.
RELEASE v0.5.1: destructive removal is enabled. Use only on a Windows system you control, after reviewing the source and understanding the risks. A verified backup is mandatory before removal. Runtime exceptions are classified by impact; non-blocking failures require explicit Y/N consent, while backup integrity, ambiguous process identity, failed Edge Update quiescence, and inventory failures remain hard blockers. Restore is blocked unless the manifest records that removal actually started.
After a completed removal workflow, the user may immediately delete all backups without returning to the main menu.
One removal confirmation starts the workflow. Removal begins automatically only after all mandatory backup checks pass. Failed preparation/validation removes this run's backup when the original startup settings were restored successfully. After a fully successful removal, the user may choose whether to delete backups.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
# Release v0.5.1: destructive removal is enabled after mandatory backup validation.
$script:EnableRemovalExecution = $true
$script:RemovalFindings = New-Object 'System.Collections.Generic.List[object]'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'This tool only runs on Windows / 此工具只能在 Windows 上运行。' -ForegroundColor Red
    exit 1
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
}

function Set-ObjectPropertyValue {
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string]$Name,
        [AllowNull()]$Value
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

function Add-RemovalFinding {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Low','Moderate','High')][string]$Severity,
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][string]$Target,
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$true)][string]$ImpactZh,
        [Parameter(Mandatory=$true)][string]$ImpactEn
    )
    $finding = [pscustomobject]@{
        Severity = $Severity
        Stage = $Stage
        Target = $Target
        Message = $Message
        ImpactZh = $ImpactZh
        ImpactEn = $ImpactEn
        Prompted = $false
        UserAccepted = $false
        CreatedAt = (Get-Date).ToString('o')
    }
    [void]$script:RemovalFindings.Add($finding)
    Write-Log ("Non-blocking removal exception [{0}] at {1} for '{2}': {3}" -f $Severity, $Stage, $Target, $Message) 'WARN'
}

function Confirm-RemovalContinuation {
    param([Parameter(Mandatory=$true)][string]$Stage)
    $pending = @($script:RemovalFindings | Where-Object { $_.Stage -eq $Stage -and -not $_.Prompted })
    if ($pending.Count -eq 0) { return }

    Write-Host ''
    Write-Host (Get-UiText 'RuntimeExceptionHeading') -ForegroundColor Yellow
    foreach ($finding in $pending) {
        $severityLabel = switch ($finding.Severity) {
            'Low' { Get-UiText 'SeverityLow' }
            'Moderate' { Get-UiText 'SeverityModerate' }
            'High' { Get-UiText 'SeverityHigh' }
        }
        Write-Host ("[{0}] {1}" -f $severityLabel, $finding.Target) -ForegroundColor Yellow
        Write-Host ("  {0}" -f $finding.Message) -ForegroundColor Gray
        $impactText = if ($script:Language -eq 'zh') { $finding.ImpactZh } else { $finding.ImpactEn }
        Write-Host ("  {0}: {1}" -f (Get-UiText 'ImpactLabel'), $impactText) -ForegroundColor Cyan
    }
    Write-Host (Get-UiText 'RuntimeExceptionSafetyNote') -ForegroundColor Yellow
    $answer = Read-Host (Get-UiText 'ContinueAfterException')
    foreach ($finding in $pending) { $finding.Prompted = $true }
    if (-not [string]::Equals(([string]$answer).Trim(), 'Y', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log ("User declined continuation after reviewing {0} non-blocking exception(s) at stage {1}; attempting to restore the pre-removal state." -f $pending.Count, $Stage) 'WARN'
        throw [System.OperationCanceledException]::new("User declined continuation at stage '$Stage'. Automatic rollback is required before temporary backup cleanup.")
    }
    foreach ($finding in $pending) { $finding.UserAccepted = $true }
    Write-Log ("User explicitly accepted continuation after {0} exception(s) at stage {1}." -f $pending.Count, $Stage) 'WARN'
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Administrator permission is required / 需要管理员权限。' -ForegroundColor Yellow
    Write-Host 'No new window will be opened. Start Windows PowerShell using "Run as administrator", then run this command again.' -ForegroundColor Yellow
    Write-Host '不会自动打开新窗口。请先以管理员身份启动 Windows PowerShell，再执行启动命令。' -ForegroundColor Yellow
    return
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
    Add-UniquePath $paths (Join-Path $env:ProgramFiles 'Microsoft\EdgeUpdate')
    if (${env:ProgramFiles(x86)}) {
        Add-UniquePath $paths (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeCore')
        Add-UniquePath $paths (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate')
    }
    foreach ($profile in (Get-UserProfiles)) {
        Add-UniquePath $paths (Join-Path $profile.LocalPath 'AppData\Local\Microsoft\Edge')
        foreach ($leaf in @('EdgeCore','EdgeUpdate')) {
            $candidate = Join-Path $profile.LocalPath ('AppData\Local\Microsoft\' + $leaf)
            if (Test-Path -LiteralPath $candidate) { Add-UniquePath $paths $candidate }
        }
    }
    # EdgeUpdate is included for backup/removal. Microsoft\EdgeWebView is intentionally excluded.
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
        'HKLM\SOFTWARE\Microsoft\Edge',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Edge',
        'HKCU\SOFTWARE\Microsoft\Edge',
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
    # These keys are snapshotted for restoration, including shell pin state and updater service registrations.
    @(
        'HKLM\SOFTWARE\Microsoft\Edge',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Edge',
        'HKCU\SOFTWARE\Microsoft\Edge',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount',
        'HKLM\SYSTEM\CurrentControlSet\Services\edgeupdate',
        'HKLM\SYSTEM\CurrentControlSet\Services\edgeupdatem',
        'HKLM\SYSTEM\CurrentControlSet\Services\MicrosoftEdgeElevationService'
    )
}

function Get-EdgeServices {
    # Fail closed if CIM cannot enumerate services. Silently treating a query failure as
    # an empty list could create an incomplete backup or falsely report service cleanup.
    try {
        $allServices = @(Get-CimInstance Win32_Service -ErrorAction Stop)
    } catch {
        Write-Log "Unable to enumerate Windows services; refusing to continue: $($_.Exception.Message)" 'ERROR'
        throw "Unable to enumerate Windows services. No destructive operation may proceed. $($_.Exception.Message)"
    }

    # A service registry key without a corresponding Win32_Service row is ambiguous
    # (for example, a damaged or deletion-pending service). Do not silently classify it
    # as absent during backup or final cleanup verification.
    foreach ($knownName in @('edgeupdate','edgeupdatem','MicrosoftEdgeElevationService')) {
        $serviceKey = 'HKLM\SYSTEM\CurrentControlSet\Services\' + $knownName
        $keyExists = Test-NativeRegistryKey $serviceKey
        $serviceFound = @($allServices | Where-Object { [string]$_.Name -ieq $knownName }).Count -gt 0
        if ($keyExists -and -not $serviceFound) {
            $message = "Service registry key exists but Win32_Service did not return the service: $knownName"
            Write-Log $message 'ERROR'
            throw $message
        }
    }

    return @($allServices | Where-Object {
        $_.Name -match '^(edgeupdate|edgeupdatem|MicrosoftEdgeElevationService)$' -or
        ($_.DisplayName -match '(?i)Microsoft Edge Update|Microsoft Edge Elevation')
    })
}
function Get-EdgeTasks {
    # Scheduled task actions have different schemas. Exec actions expose Execute/Arguments,
    # while COM-handler and other action types may not. Do not dereference absent properties
    # under Set-StrictMode; inspect the property collection first.
    # Fail closed on enumeration errors instead of treating an inaccessible task library as empty.
    try {
        $all = @(Get-ScheduledTask -ErrorAction Stop)
    } catch {
        Write-Log "Unable to enumerate scheduled tasks; refusing to continue: $($_.Exception.Message)" 'ERROR'
        throw "Unable to enumerate scheduled tasks. No destructive operation may proceed. $($_.Exception.Message)"
    }
    foreach ($task in $all) {
        $taskName = [string]$task.TaskName
        $taskPath = [string]$task.TaskPath
        $matchesIdentity = ($taskName -match '(?i)MicrosoftEdgeUpdate|EdgeUpdate') -or
                           ($taskPath -match '(?i)\\Microsoft\\EdgeUpdate\\')
        $actionText = New-Object 'System.Collections.Generic.List[string]'
        $actionsProperty = $task.PSObject.Properties['Actions']
        if ($actionsProperty -and $null -ne $actionsProperty.Value) {
            foreach ($action in @($actionsProperty.Value)) {
                if ($null -eq $action) { continue }
                $parts = New-Object 'System.Collections.Generic.List[string]'
                foreach ($propertyName in @('Execute','Arguments','ClassId','Data')) {
                    $property = $action.PSObject.Properties[$propertyName]
                    if ($property -and $null -ne $property.Value) {
                        [void]$parts.Add([string]$property.Value)
                    }
                }
                if ($parts.Count -gt 0) { [void]$actionText.Add(($parts -join ' ')) }
            }
        }
        $matchesAction = (($actionText -join ' ') -match '(?i)Microsoft\\EdgeUpdate|edgeupdate')
        if ($matchesIdentity -or $matchesAction) { $task }
    }
}

function Invoke-Robocopy {
    param([string]$Source, [string]$Destination, [switch]$Mirror)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $mode = if ($Mirror) { '/MIR' } else { '/E' }
    & "$env:SystemRoot\System32\robocopy.exe" $Source $Destination $mode '/COPYALL' '/DCOPY:DAT' '/R:1' '/W:1' '/XJ' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { throw "Robocopy failed (exit code $code): $Source" }
    Write-Log ("Robocopy completed with exit code {0}; mode={1}; source='{2}'; destination='{3}'." -f $code, $mode, $Source, $Destination) 'INFO'
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

function Get-DirectoryInventory {
    param([Parameter(Mandatory=$true)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Directory not found for validation: $root"
    }
    $fileRecords = New-Object 'System.Collections.Generic.List[string]'
    $directoryRecords = New-Object 'System.Collections.Generic.List[string]'
    $totalBytes = [long]0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            # Do not follow junctions/reparse points; the backup command uses /XJ as well.
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $relative = $item.FullName.Substring($root.Length).TrimStart('\')
            if ($item.PSIsContainer) {
                $directoryRecords.Add($relative)
                $stack.Push($item.FullName)
            } else {
                # Compare actual file content, not just names and sizes. This can take several minutes
                # for large browser profiles, but prevents a same-size corrupt file passing validation.
                $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                $fileRecords.Add(('{0}|{1}|{2}' -f $relative, [long]$item.Length, $hash))
                $totalBytes += [long]$item.Length
            }
        }
    }
    return [pscustomobject]@{
        FileRecords = @($fileRecords | Sort-Object)
        DirectoryRecords = @($directoryRecords | Sort-Object)
        FileCount = $fileRecords.Count
        DirectoryCount = $directoryRecords.Count
        TotalBytes = $totalBytes
        HashAlgorithm = 'SHA256'
    }
}

function Test-BackupEntryIntegrity {
    param([Parameter(Mandatory=$true)]$Entry)
    if (-not (Test-Path -LiteralPath $Entry.BackupPath)) {
        throw "Backup path does not exist: $($Entry.BackupPath)"
    }
    if (-not (Test-Path -LiteralPath $Entry.OriginalPath)) {
        throw "Original path disappeared before backup validation: $($Entry.OriginalPath)"
    }
    if ($Entry.IsDirectory) {
        Write-Log "Computing SHA-256 file inventories for source and backup: $($Entry.OriginalPath). Large directories may take several minutes."
        $sourceInventory = Get-DirectoryInventory -Path $Entry.OriginalPath
        $backupInventory = Get-DirectoryInventory -Path $Entry.BackupPath
        if ($sourceInventory.FileCount -ne $backupInventory.FileCount -or
            $sourceInventory.DirectoryCount -ne $backupInventory.DirectoryCount -or
            $sourceInventory.TotalBytes -ne $backupInventory.TotalBytes -or
            (($sourceInventory.FileRecords -join "`n") -cne ($backupInventory.FileRecords -join "`n")) -or
            (($sourceInventory.DirectoryRecords -join "`n") -cne ($backupInventory.DirectoryRecords -join "`n"))) {
            throw "Backup inventory mismatch: $($Entry.OriginalPath)"
        }
        # Persist the backup-side inventory so a future restore can validate the payload
        # even after the original directory has been removed. Keep relative paths, sizes,
        # and SHA-256 values rather than rechecking only directory count/total size.
        $savedInventory = [pscustomobject]@{
            FileRecords = @($backupInventory.FileRecords)
            DirectoryRecords = @($backupInventory.DirectoryRecords)
            FileCount = [int]$backupInventory.FileCount
            DirectoryCount = [int]$backupInventory.DirectoryCount
            TotalBytes = [long]$backupInventory.TotalBytes
            HashAlgorithm = 'SHA256'
        }
        $Entry | Add-Member -MemberType NoteProperty -Name BackupInventory -Value $savedInventory -Force
    } else {
        $sourceFile = Get-Item -LiteralPath $Entry.OriginalPath -ErrorAction Stop
        $backupFile = Get-Item -LiteralPath $Entry.BackupPath -ErrorAction Stop
        if ([long]$sourceFile.Length -ne [long]$backupFile.Length) {
            throw "Backup file size mismatch: $($Entry.OriginalPath)"
        }
        $sourceHash = (Get-FileHash -LiteralPath $Entry.OriginalPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $backupHash = (Get-FileHash -LiteralPath $Entry.BackupPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($sourceHash -cne $backupHash) { throw "Backup file hash mismatch: $($Entry.OriginalPath)" }
        $Entry | Add-Member -MemberType NoteProperty -Name BackupLength -Value ([long]$backupFile.Length) -Force
        $Entry | Add-Member -MemberType NoteProperty -Name BackupHash -Value ([string]$backupHash) -Force
    }
    # Return the mutated entry so the caller can explicitly write it back into the
    # manifest array. This avoids relying only on in-place mutation semantics for
    # PSCustomObject entries across Windows PowerShell 5.1 scopes.
    return $Entry
}

function Test-PersistedBackupEntryIntegrity {
    param([Parameter(Mandatory=$true)]$Entry)
    if (-not (Test-Path -LiteralPath $Entry.BackupPath)) {
        throw "Backup payload is missing: $($Entry.BackupPath)"
    }
    if ($Entry.IsDirectory) {
        $saved = $Entry.BackupInventory
        if (-not $saved -or [string]$saved.HashAlgorithm -ne 'SHA256') {
            throw "This backup has no persisted SHA-256 inventory: $($Entry.OriginalPath)"
        }
        $actual = Get-DirectoryInventory -Path $Entry.BackupPath
        if ([int]$actual.FileCount -ne [int]$saved.FileCount -or
            [int]$actual.DirectoryCount -ne [int]$saved.DirectoryCount -or
            [long]$actual.TotalBytes -ne [long]$saved.TotalBytes -or
            (($actual.FileRecords -join "`n") -cne (@($saved.FileRecords) -join "`n")) -or
            (($actual.DirectoryRecords -join "`n") -cne (@($saved.DirectoryRecords) -join "`n"))) {
            throw "Persisted SHA-256 inventory mismatch: $($Entry.OriginalPath)"
        }
    } else {
        if ($null -eq $Entry.BackupLength -or [string]::IsNullOrWhiteSpace([string]$Entry.BackupHash)) {
            throw "This backup has no persisted file hash: $($Entry.OriginalPath)"
        }
        $file = Get-Item -LiteralPath $Entry.BackupPath -ErrorAction Stop
        if ([long]$file.Length -ne [long]$Entry.BackupLength) {
            throw "Backup file length mismatch: $($Entry.OriginalPath)"
        }
        $hash = (Get-FileHash -LiteralPath $Entry.BackupPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($hash -cne [string]$Entry.BackupHash) {
            throw "Backup file SHA-256 mismatch: $($Entry.OriginalPath)"
        }
    }
    return $true
}

function Test-RestoredFileEntryIntegrity {
    param([Parameter(Mandatory=$true)]$Entry)
    $destination = [string]$Entry.OriginalPath
    if (-not (Test-Path -LiteralPath $destination)) {
        throw "Restored destination is missing: $destination"
    }
    if ($Entry.IsDirectory) {
        $expected = $Entry.BackupInventory
        if (-not $expected -or [string]$expected.HashAlgorithm -ne 'SHA256') {
            throw "Persisted SHA-256 inventory is missing for restored directory: $destination"
        }
        $actual = Get-DirectoryInventory -Path $destination
        $fileRecordsMatch = (($actual.FileRecords -join "`n") -ceq (@($expected.FileRecords) -join "`n"))
        $directoryRecordsMatch = (($actual.DirectoryRecords -join "`n") -ceq (@($expected.DirectoryRecords) -join "`n"))
        if ([int]$actual.FileCount -ne [int]$expected.FileCount -or
            [int]$actual.DirectoryCount -ne [int]$expected.DirectoryCount -or
            [long]$actual.TotalBytes -ne [long]$expected.TotalBytes -or
            -not $fileRecordsMatch -or -not $directoryRecordsMatch) {
            # Produce bounded path-level diagnostics. A profile can contain many thousands
            # of records, so report only the first eight examples from each category.
            $expectedFileMap = @{}
            foreach ($record in @($expected.FileRecords)) {
                $separator = ([string]$record).IndexOf('|')
                if ($separator -gt 0) { $expectedFileMap[([string]$record).Substring(0, $separator).ToLowerInvariant()] = [string]$record }
            }
            $actualFileMap = @{}
            foreach ($record in @($actual.FileRecords)) {
                $separator = ([string]$record).IndexOf('|')
                if ($separator -gt 0) { $actualFileMap[([string]$record).Substring(0, $separator).ToLowerInvariant()] = [string]$record }
            }
            $missingFiles = New-Object 'System.Collections.Generic.List[string]'
            $changedFiles = New-Object 'System.Collections.Generic.List[string]'
            $extraFiles = New-Object 'System.Collections.Generic.List[string]'
            foreach ($pathKey in $expectedFileMap.Keys) {
                if (-not $actualFileMap.ContainsKey($pathKey)) {
                    if ($missingFiles.Count -lt 8) { [void]$missingFiles.Add($pathKey) }
                } elseif ($expectedFileMap[$pathKey] -cne $actualFileMap[$pathKey]) {
                    if ($changedFiles.Count -lt 8) { [void]$changedFiles.Add($pathKey) }
                }
            }
            foreach ($pathKey in $actualFileMap.Keys) {
                if (-not $expectedFileMap.ContainsKey($pathKey) -and $extraFiles.Count -lt 8) { [void]$extraFiles.Add($pathKey) }
            }
            $expectedDirectories = @{}; foreach ($pathKey in @($expected.DirectoryRecords)) { $expectedDirectories[([string]$pathKey).ToLowerInvariant()] = $true }
            $actualDirectories = @{}; foreach ($pathKey in @($actual.DirectoryRecords)) { $actualDirectories[([string]$pathKey).ToLowerInvariant()] = $true }
            $missingDirectories = @($expectedDirectories.Keys | Where-Object { -not $actualDirectories.ContainsKey($_) } | Select-Object -First 8)
            $extraDirectories = @($actualDirectories.Keys | Where-Object { -not $expectedDirectories.ContainsKey($_) } | Select-Object -First 8)
            $details = New-Object 'System.Collections.Generic.List[string]'
            [void]$details.Add(('Files expected/actual={0}/{1}; directories expected/actual={2}/{3}; bytes expected/actual={4}/{5}' -f $expected.FileCount, $actual.FileCount, $expected.DirectoryCount, $actual.DirectoryCount, $expected.TotalBytes, $actual.TotalBytes))
            if ($missingFiles.Count) { [void]$details.Add(('Missing files (first {0}): {1}' -f $missingFiles.Count, ($missingFiles -join ', '))) }
            if ($changedFiles.Count) { [void]$details.Add(('Changed size/hash files (first {0}): {1}' -f $changedFiles.Count, ($changedFiles -join ', '))) }
            if ($extraFiles.Count) { [void]$details.Add(('Unexpected files (first {0}): {1}' -f $extraFiles.Count, ($extraFiles -join ', '))) }
            if ($missingDirectories.Count) { [void]$details.Add(('Missing directories (first {0}): {1}' -f $missingDirectories.Count, ($missingDirectories -join ', '))) }
            if ($extraDirectories.Count) { [void]$details.Add(('Unexpected directories (first {0}): {1}' -f $extraDirectories.Count, ($extraDirectories -join ', '))) }
            throw ("Restored directory does not match its verified backup inventory: {0}. {1}" -f $destination, ($details -join '; '))
        }
    } else {
        if ($null -eq $Entry.BackupLength -or [string]::IsNullOrWhiteSpace([string]$Entry.BackupHash)) {
            throw "Persisted SHA-256 metadata is missing for restored file: $destination"
        }
        $actualFile = Get-Item -LiteralPath $destination -ErrorAction Stop
        if ([long]$actualFile.Length -ne [long]$Entry.BackupLength) {
            throw "Restored file length mismatch: $destination"
        }
        $actualHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actualHash -cne [string]$Entry.BackupHash) {
            throw "Restored file SHA-256 mismatch: $destination"
        }
    }
    return $true
}

function Get-RegistryValueState {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $keyExisted = Test-Path -LiteralPath $Path
    $exists = $false
    $value = $null
    $kind = $null
    if ($keyExisted) {
        $key = $null
        try {
            $key = Get-Item -LiteralPath $Path -ErrorAction Stop
            if (@($key.GetValueNames()) -contains $Name) {
                $exists = $true
                $kind = $key.GetValueKind($Name).ToString()
                $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        } finally {
            if ($key) { $key.Close() }
        }
    }
    return [pscustomobject]@{
        Path = $Path
        Name = $Name
        KeyExisted = [bool]$keyExisted
        Exists = [bool]$exists
        Kind = $kind
        Value = $value
    }
}

function Get-EdgeStartupState {
    # Capture original settings before changing anything. Startup Boost can restart Edge
    # after a window closes, while this machine has a per-user Run entry that starts Edge
    # at sign-in with --win-session-start. WebView2 is not targeted.
    $preferenceTargets = @(
        [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Edge\StartupBoost'; Name = 'StartupBoostEnabled' },
        [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Edge'; Name = 'BackgroundModeEnabled' }
    )
    $settings = @(
        foreach ($target in $preferenceTargets) {
            Get-RegistryValueState -Path $target.Path -Name $target.Name
        }
    )

    $runValues = New-Object 'System.Collections.Generic.List[object]'
    $runPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path -LiteralPath $runPath) {
        $runKey = $null
        try {
            $runKey = Get-Item -LiteralPath $runPath -ErrorAction Stop
            foreach ($name in @($runKey.GetValueNames())) {
                $value = [string]$runKey.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $isEdgeAutoLaunch = ($name -match '(?i)^MicrosoftEdgeAutoLaunch_') -and
                                    ($value -match '(?i)\\Microsoft\\Edge\\Application\\msedge\.exe')
                $isWinSessionStart = ($value -match '(?i)\\Microsoft\\Edge\\Application\\msedge\.exe') -and
                                     ($value -match '(?i)--win-session-start')
                if ($isEdgeAutoLaunch -or $isWinSessionStart) {
                    $runValues.Add((Get-RegistryValueState -Path $runPath -Name $name))
                }
            }
        } finally {
            if ($runKey) { $runKey.Close() }
        }
    }

    # Read-only policy detection. The tool does not overwrite administrator-managed policies.
    $policyValues = New-Object 'System.Collections.Generic.List[object]'
    $policyRoots = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge',
        'HKCU:\SOFTWARE\Policies\Microsoft\Edge',
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge\Recommended',
        'HKCU:\SOFTWARE\Policies\Microsoft\Edge\Recommended'
    )
    foreach ($policyPath in $policyRoots) {
        foreach ($name in @('StartupBoostEnabled','BackgroundModeEnabled')) {
            $policyState = Get-RegistryValueState -Path $policyPath -Name $name
            if ($policyState.Exists) { $policyValues.Add($policyState) }
        }
    }

    return [pscustomobject]@{
        SchemaVersion = 1
        CapturedAt = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        PreferenceValues = @($settings)
        RunValues = @($runValues.ToArray())
        PolicyValues = @($policyValues.ToArray())
    }
}

function New-BackupStagingDirectory {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupDir = Join-Path $script:BackupRoot $stamp
    if (Test-Path -LiteralPath $backupDir) {
        throw "A backup directory with the generated timestamp already exists; refusing to reuse it: $backupDir"
    }
    New-Item -ItemType Directory -Path $backupDir -ErrorAction Stop | Out-Null
    return $backupDir
}

function Remove-CurrentRunBackup {
    param(
        [Parameter(Mandatory=$true)][string]$BackupDirectory,
        [AllowNull()][string]$PreviousLatestBackup
    )
    $rootFull = [IO.Path]::GetFullPath($script:BackupRoot).TrimEnd('\')
    $candidateFull = [IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\')
    $candidateParent = [IO.Path]::GetDirectoryName($candidateFull)
    $candidateLeaf = [IO.Path]::GetFileName($candidateFull)

    # Never allow cleanup-on-failure to recursively delete anything except the
    # timestamped, direct child created by this tool under its own backup root.
    if ($candidateParent -ine $rootFull -or $candidateLeaf -notmatch '^\d{8}-\d{6}-\d{3}$') {
        Write-Log "Refusing cleanup of unexpected backup path: $candidateFull" 'ERROR'
        return $false
    }
    if (-not (Test-Path -LiteralPath $candidateFull -PathType Container)) { return $true }

    try {
        Remove-Item -LiteralPath $candidateFull -Recurse -Force -ErrorAction Stop
        Write-Log "Removed this run's incomplete backup: $candidateFull" 'OK'
    } catch {
        Write-Log "Could not remove this run's incomplete backup '$candidateFull': $($_.Exception.Message). It is retained for manual inspection/recovery." 'ERROR'
        return $false
    }

    [void](Set-LatestRestoreEligibleBackupPointer -CurrentBackupDirectoryToExclude $candidateFull -PreferredBackupDirectory $PreviousLatestBackup)
    return $true
}

function Set-LatestRestoreEligibleBackupPointer {
    param(
        [Parameter(Mandatory=$true)][string]$CurrentBackupDirectoryToExclude,
        [AllowNull()][string]$PreferredBackupDirectory
    )
    $pointerPath = Join-Path $script:BackupRoot 'latest-backup.txt'
    $excludedFull = [IO.Path]::GetFullPath($CurrentBackupDirectoryToExclude).TrimEnd('\')

    # Only repair the pointer if it currently targets this run's backup. Do not
    # overwrite a pointer another process may have changed independently.
    try {
        if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
            $currentPointer = (Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
            if ($currentPointer.Length -gt 0 -and $currentPointer[0] -eq [char]0xFEFF) {
                $currentPointer = $currentPointer.Substring(1).Trim()
            }
            if ($currentPointer -and ([IO.Path]::GetFullPath($currentPointer).TrimEnd('\') -ine $excludedFull)) {
                return $true
            }
        } else {
            return $true
        }

        $eligible = $null
        if (-not [string]::IsNullOrWhiteSpace($PreferredBackupDirectory) -and
            (Test-Path -LiteralPath $PreferredBackupDirectory -PathType Container) -and
            ([IO.Path]::GetFullPath($PreferredBackupDirectory).TrimEnd('\') -ine $excludedFull) -and
            (Test-BackupRestoreEligible -BackupDirectory $PreferredBackupDirectory)) {
            $eligible = [IO.Path]::GetFullPath($PreferredBackupDirectory).TrimEnd('\')
        }

        if (-not $eligible) {
            $eligibleDirectory = Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction Stop |
                Where-Object {
                    [IO.Path]::GetFullPath($_.FullName).TrimEnd('\') -ine $excludedFull -and
                    (Test-BackupRestoreEligible -BackupDirectory $_.FullName)
                } |
                Sort-Object Name -Descending |
                Select-Object -First 1
            if ($eligibleDirectory) { $eligible = [IO.Path]::GetFullPath($eligibleDirectory.FullName).TrimEnd('\') }
        }

        if ($eligible) {
            Set-Content -LiteralPath $pointerPath -Value $eligible -Encoding UTF8 -ErrorAction Stop
            Write-Log "Latest-backup pointer now targets a restore-eligible backup: $eligible" 'OK'
        } else {
            if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
                Remove-Item -LiteralPath $pointerPath -Force -ErrorAction Stop
            }
            Write-Log 'Removed latest-backup pointer because no restore-eligible backup remains. Ineligible staged/incomplete backups are not exposed as restore targets.' 'WARN'
        }
        return $true
    } catch {
        Write-Log "Could not repair latest-backup pointer safely: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Set-RegistryValueState {
    param([Parameter(Mandatory=$true)]$State)
    $path = [string]$State.Path
    $name = [string]$State.Name
    if ($State.Exists) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -Force -ErrorAction Stop | Out-Null
        }
        $propertyType = switch ([string]$State.Kind) {
            'String' { 'String' }
            'ExpandString' { 'ExpandString' }
            'Binary' { 'Binary' }
            'DWord' { 'DWord' }
            'MultiString' { 'MultiString' }
            'QWord' { 'QWord' }
            default { throw "Unsupported registry value type '$($State.Kind)' for $path\$name" }
        }
        New-ItemProperty -LiteralPath $path -Name $name -Value $State.Value -PropertyType $propertyType -Force -ErrorAction Stop | Out-Null
    } else {
        if (Test-Path -LiteralPath $path) {
            $key = $null
            $valueExists = $false
            try {
                $key = Get-Item -LiteralPath $path -ErrorAction Stop
                $valueExists = (@($key.GetValueNames()) -contains $name)
            } finally {
                if ($key) { $key.Close() }
            }
            if ($valueExists) {
                Remove-ItemProperty -LiteralPath $path -Name $name -Force -ErrorAction Stop
            }
            if (-not $State.KeyExisted) {
                $key = $null
                $isEmpty = $false
                try {
                    if (Test-Path -LiteralPath $path) {
                        $key = Get-Item -LiteralPath $path -ErrorAction Stop
                        $isEmpty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0)
                    }
                } finally {
                    if ($key) { $key.Close() }
                }
                if ($isEmpty) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            }
        }
    }
}

function Disable-EdgeStartupMechanisms {
    param([Parameter(Mandatory=$true)]$State)
    Write-Log 'Temporarily disabling Edge Startup Boost, background mode, and user auto-launch before stopping Edge.'
    foreach ($setting in @($State.PreferenceValues)) {
        if (-not (Test-Path -LiteralPath $setting.Path)) {
            New-Item -Path $setting.Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $verifiedPreference = Get-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -ErrorAction Stop
        $verifiedPreferenceValue = $verifiedPreference.PSObject.Properties[[string]$setting.Name].Value
        if ([int]$verifiedPreferenceValue -ne 0) {
            throw "Edge startup preference did not remain disabled: $($setting.Path)\$($setting.Name)"
        }
        Write-Log "Temporarily disabled and verified Edge startup preference: $($setting.Path)\$($setting.Name)" 'OK'
    }
    foreach ($runValue in @($State.RunValues)) {
        if (Test-Path -LiteralPath $runValue.Path) {
            Remove-ItemProperty -LiteralPath $runValue.Path -Name $runValue.Name -Force -ErrorAction SilentlyContinue
            $stillExists = $false
            $runKey = $null
            try {
                $runKey = Get-Item -LiteralPath $runValue.Path -ErrorAction Stop
                $stillExists = (@($runKey.GetValueNames()) -contains [string]$runValue.Name)
            } finally {
                if ($runKey) { $runKey.Close() }
            }
            if ($stillExists) { throw "Could not disable Edge auto-launch value: $($runValue.Path)\$($runValue.Name)" }
            Write-Log "Temporarily removed Edge auto-launch value: $($runValue.Name)" 'OK'
        }
    }
    foreach ($policy in @($State.PolicyValues)) {
        if ([string]$policy.Name -in @('StartupBoostEnabled','BackgroundModeEnabled') -and ([string]$policy.Value -eq '1')) {
            Write-Log "An Edge policy enables $($policy.Name) at $($policy.Path); policy was not modified. The process-stability check will determine whether stopping Edge is reliable." 'WARN'
        }
    }
}

function Restore-EdgeStartupMechanisms {
    param([Parameter(Mandatory=$true)]$State)
    if (-not $State) { return $true }
    $restoreFailed = $false
    foreach ($setting in @($State.PreferenceValues)) {
        try {
            Set-RegistryValueState -State $setting
            Write-Log "Restored Edge startup preference: $($setting.Path)\$($setting.Name)" 'OK'
        } catch {
            $restoreFailed = $true
            Write-Log "Could not restore Edge startup preference $($setting.Path)\$($setting.Name): $($_.Exception.Message)" 'ERROR'
        }
    }
    foreach ($runValue in @($State.RunValues)) {
        try {
            Set-RegistryValueState -State $runValue
            Write-Log "Restored Edge auto-launch value: $($runValue.Name)" 'OK'
        } catch {
            $restoreFailed = $true
            Write-Log "Could not restore Edge auto-launch value $($runValue.Name): $($_.Exception.Message)" 'ERROR'
        }
    }
    return (-not $restoreFailed)
}

function Remove-EdgeAutoLaunchRunValues {
    # Final cleanup sweep: the Edge uninstaller could recreate a Run entry after the
    # pre-backup quiescing step. Remove only values that clearly launch the desktop Edge.
    $runPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $runPath)) { return }
    $namesToRemove = New-Object 'System.Collections.Generic.List[string]'
    $runKey = $null
    try {
        $runKey = Get-Item -LiteralPath $runPath -ErrorAction Stop
        foreach ($name in @($runKey.GetValueNames())) {
            $value = [string]$runKey.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $isEdgeAutoLaunch = ($name -match '(?i)^MicrosoftEdgeAutoLaunch_') -and
                                ($value -match '(?i)\\Microsoft\\Edge\\Application\\msedge\.exe')
            $isWinSessionStart = ($value -match '(?i)\\Microsoft\\Edge\\Application\\msedge\.exe') -and
                                 ($value -match '(?i)--win-session-start')
            if ($isEdgeAutoLaunch -or $isWinSessionStart) { $namesToRemove.Add([string]$name) }
        }
    } finally {
        if ($runKey) { $runKey.Close() }
    }
    foreach ($name in $namesToRemove) {
        Remove-ItemProperty -LiteralPath $runPath -Name $name -Force -ErrorAction Stop
        Write-Log "Removed traditional Edge auto-launch value during final cleanup: $name" 'OK'
    }
}

function New-PreRemovalBackup {
    param(
        [Parameter(Mandatory=$true)][string]$BackupDirectory,
        [Parameter(Mandatory=$true)]$StartupState
    )
    $backupDir = $BackupDirectory
    $payload = Join-Path $backupDir 'Payload'
    $regDir = Join-Path $backupDir 'Registry'
    $taskDir = Join-Path $backupDir 'Tasks'
    $snapshotDir = Join-Path $backupDir 'RegistrySnapshots'
    New-Item -ItemType Directory -Path $payload, $regDir, $taskDir, $snapshotDir -Force -ErrorAction Stop | Out-Null
    Write-Log "Creating mandatory pre-removal backup: $backupDir"

    $manifest = [ordered]@{
        SchemaVersion = 3
        CreatedAt = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        FileEntries = @()
        RegistryEntries = @()
        RegistrySnapshots = @()
        Services = @()
        Tasks = @()
        StartupState = $StartupState
        BackupStatus = 'InProgress'
        BackupWarnings = @()
        RemovalState = 'NotStarted'
        RemovalStartedAt = $null
        RemovalCompletedAt = $null
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

    $validatedFileEntries = 0
    # Use indexed assignment to persist BackupInventory / BackupHash / BackupLength
    # back into the manifest entries before manifest.json is serialized.
    for ($entryIndex = 0; $entryIndex -lt $manifest.FileEntries.Count; $entryIndex++) {
        $entry = $manifest.FileEntries[$entryIndex]
        if ($null -eq $entry) { continue }
        try {
            $validatedEntry = Test-BackupEntryIntegrity -Entry $entry
            $manifest.FileEntries[$entryIndex] = $validatedEntry
            $validatedFileEntries++
            Write-Log "Backup integrity check passed: $($entry.OriginalPath)" 'OK'
        } catch {
            $manifest.BackupWarnings += "Backup validation failed: $($entry.OriginalPath) -- $($_.Exception.Message)"
            Write-Log "Backup validation failed for '$($entry.OriginalPath)': $($_.Exception.Message)" 'ERROR'
        }
    }
    $manifest.BackupValidation = [pscustomobject]@{
        FileEntriesFound = $fileTargets.Count
        FileEntriesRecorded = @($manifest.FileEntries).Count
        FileEntriesValidated = $validatedFileEntries
        HashAlgorithm = 'SHA256'
        DirectoryFileContentsHashed = $true
        CheckedAt = (Get-Date).ToString('o')
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
        $serviceSddl = ''
        try {
            $sddlOutput = @(& "$env:SystemRoot\System32\sc.exe" sdshow $svc.Name 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "sc.exe sdshow exit code $LASTEXITCODE" }
            $sddlLine = @($sddlOutput | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^D:' } | Select-Object -First 1)
            if ($sddlLine.Count -eq 0) { throw 'Service security descriptor was not returned.' }
            $serviceSddl = [string]$sddlLine[0]
        } catch {
            $manifest.BackupWarnings += "Service security descriptor backup failed: $($svc.Name) -- $($_.Exception.Message)"
            Write-Log "Could not back up service security descriptor for '$($svc.Name)': $($_.Exception.Message)" 'ERROR'
        }
        if ([string]::IsNullOrWhiteSpace([string]$svc.PathName)) {
            $manifest.BackupWarnings += "Service recovery metadata missing PathName: $($svc.Name)"
            Write-Log "Service recovery metadata missing PathName: $($svc.Name)" 'ERROR'
        }
        if ([string]::IsNullOrWhiteSpace([string]$serviceSddl)) {
            # The security-descriptor failure above already records a warning, but keep the
            # manifest requirement explicit so a service cannot be marked restorable without it.
            if (-not (@($manifest.BackupWarnings) -match [regex]::Escape("Service security descriptor backup failed: $($svc.Name)"))) {
                $manifest.BackupWarnings += "Service security descriptor is missing: $($svc.Name)"
            }
        }
        $manifest.Services += [pscustomobject]@{
            Name = $svc.Name
            DisplayName = $svc.DisplayName
            StartMode = $svc.StartMode
            WasRunning = ($svc.State -eq 'Running')
            State = $svc.State
            PathName = [string]$svc.PathName
            StartName = [string]$svc.StartName
            ServiceType = [string]$svc.ServiceType
            ErrorControl = [string]$svc.ErrorControl
            SecurityDescriptor = $serviceSddl
        }
    }

    foreach ($task in @(Get-EdgeTasks)) {
        $taskName = [string]$task.TaskName
        $taskPath = [string]$task.TaskPath
        try {
            $settingsProperty = $task.PSObject.Properties['Settings']
            $settings = if ($settingsProperty) { $settingsProperty.Value } else { $null }
            $enabledProperty = if ($settings) { $settings.PSObject.Properties['Enabled'] } else { $null }
            if (-not $enabledProperty) {
                throw 'Scheduled task enabled state is unavailable; exact restoration cannot be guaranteed.'
            }
            $wasEnabled = [bool]$enabledProperty.Value
            $xml = Export-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace([string]$xml)) {
                throw 'Export-ScheduledTask returned an empty task definition.'
            }
            $fileName = ('Task-{0:D4}.xml' -f ($manifest.Tasks.Count + 1))
            $xmlPath = Join-Path $taskDir $fileName
            Set-Content -LiteralPath $xmlPath -Value $xml -Encoding Unicode -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
                throw 'Scheduled task XML backup file was not created.'
            }
            $manifest.Tasks += [pscustomobject]@{
                TaskName = $taskName; TaskPath = $taskPath
                WasEnabled = $wasEnabled; BackupFile = $xmlPath
            }
            Write-Log "Backed up scheduled task: $taskPath$taskName" 'OK'
        } catch {
            $manifest.BackupWarnings += "Scheduled task backup failed: $taskPath$taskName -- $($_.Exception.Message)"
            Write-Log "Could not back up scheduled task '$taskPath$taskName': $($_.Exception.Message)" 'ERROR'
        }
    }

    # Hash all auxiliary backup files too, not just the copied file/directory payload.
    foreach ($groupName in @('RegistryEntries', 'RegistrySnapshots', 'Tasks')) {
        $records = @($manifest[$groupName])
        for ($recordIndex = 0; $recordIndex -lt $records.Count; $recordIndex++) {
            $record = $records[$recordIndex]
            if ($null -eq $record -or [string]::IsNullOrWhiteSpace([string]$record.BackupFile)) {
                $manifest.BackupWarnings += "Backup metadata missing file path in group $groupName at index $recordIndex"
                Write-Log "Backup metadata missing file path in group $groupName at index $recordIndex" 'ERROR'
                continue
            }
            try {
                $recordPath = [string]$record.BackupFile
                if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
                    throw "Backup file not found: $recordPath"
                }
                if ($groupName -ne 'Tasks') {
                    $firstLine = Get-Content -LiteralPath $recordPath -TotalCount 1 -ErrorAction Stop
                    if ([string]$firstLine -notmatch 'Windows Registry Editor Version 5\.00') {
                        throw "Invalid .reg header: $recordPath"
                    }
                } else {
                    $xmlDocument = New-Object System.Xml.XmlDocument
                    $xmlDocument.Load($recordPath)
                    if ($xmlDocument.DocumentElement.LocalName -ne 'Task') {
                        throw "Invalid scheduled-task XML root: $recordPath"
                    }
                }
                $recordFile = Get-Item -LiteralPath $recordPath -ErrorAction Stop
                $recordHash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256 -ErrorAction Stop).Hash
                $record | Add-Member -MemberType NoteProperty -Name BackupLength -Value ([long]$recordFile.Length) -Force
                $record | Add-Member -MemberType NoteProperty -Name BackupHash -Value ([string]$recordHash) -Force
                $records[$recordIndex] = $record
            } catch {
                $manifest.BackupWarnings += "Backup metadata/hash validation failed for $groupName item $recordIndex -- $($_.Exception.Message)"
                Write-Log "Backup metadata/hash validation failed for $groupName item $recordIndex`: $($_.Exception.Message)" 'ERROR'
            }
        }
        $manifest[$groupName] = $records
    }

    # Validate service-to-snapshot coverage before declaring the backup complete.
    # Restore-time validation alone is too late: the user must not receive a backup
    # marked Complete if a service record has no unique registry snapshot.
    foreach ($svc in @($manifest.Services)) {
        $expectedServiceKey = 'HKLM\SYSTEM\CurrentControlSet\Services\' + [string]$svc.Name
        $serviceSnapshots = @($manifest.RegistrySnapshots | Where-Object {
            [string]$_.NativePath -ieq $expectedServiceKey
        })
        if ($serviceSnapshots.Count -ne 1) {
            $manifest.BackupWarnings += "Service registry snapshot validation failed for $($svc.Name): expected exactly one snapshot, found $($serviceSnapshots.Count)."
            Write-Log "Service registry snapshot validation failed for '$($svc.Name)': expected exactly one snapshot, found $($serviceSnapshots.Count)." 'ERROR'
        }
    }

    $manifestPath = Join-Path $backupDir 'manifest.json'
    if ($manifest.BackupWarnings.Count -gt 0) {
        $manifest.BackupStatus = 'Incomplete'
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        Write-Log 'Backup is incomplete. No Edge removal will be attempted; the caller will clean up this run after restoring startup settings.' 'ERROR'
        throw "Backup incomplete. Removal was not attempted: $backupDir"
    }
    $manifest.BackupStatus = 'Complete'
    $manifest.BackupCompletedAt = (Get-Date).ToString('o')
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:BackupRoot 'latest-backup.txt') -Value $backupDir -Encoding UTF8
    Write-Log 'Mandatory backup completed successfully.' 'OK'
    return $backupDir
}

function Invoke-UnpinAttempt {
    param([string]$ShortcutPath)
    # Shell unpin verbs only make sense for actual per-user pinned shortcut folders.
    # Trying them on common Desktop/Start Menu links can produce irrelevant Access Denied warnings.
    if ($ShortcutPath -notmatch '(?i)User Pinned\\(?:TaskBar|StartMenu)') { return }
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
    } catch {
        Add-RemovalFinding -Severity 'Low' -Stage 'Shortcuts' -Target $ShortcutPath -Message ("Could not invoke shell unpin action: {0}" -f $_.Exception.Message) -ImpactZh 'Windows 外壳的取消固定操作失败；这通常只影响开始菜单或任务栏图钉，不代表 Edge 主程序未删除。' -ImpactEn 'The shell unpin operation failed. This usually affects only Start/taskbar pins and does not mean the Edge browser executable remains.'
    }
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
                        $pinLogMessage = 'Requested shell pin action "{0}" for {1}' -f $name, $ShortcutPath
                        Write-Log -Message $pinLogMessage -Level 'INFO'
                    }
                }
            }
        }
        if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    } catch { Write-Log "Could not restore pin state for ${ShortcutPath}: $($_.Exception.Message)" 'WARN' }
}

function Get-TraditionalEdgeProcesses {
    # Match the traditional desktop browser executable, not msedgewebview2.exe.
    # WebView2 has a different executable name and is never targeted here.
    $known = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop)
    $matching = @($known | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath -match '(?i)\\Microsoft\\Edge(?:Core)?\\Application\\msedge\.exe$'
    })
    $unresolved = @($known | Where-Object { [string]::IsNullOrWhiteSpace($_.ExecutablePath) })
    if ($unresolved.Count -gt 0) {
        $pidList = ($unresolved | ForEach-Object { $_.ProcessId }) -join ', '
        Write-Log ("Could not verify executable path for msedge.exe PID(s): {0}. Failing closed; no removal may proceed while process identity is unknown." -f $pidList) 'ERROR'
        throw ("Cannot safely verify the executable path for msedge.exe PID(s): {0}. No removal may proceed." -f $pidList)
    }
    return $matching
}

function Stop-TraditionalEdgeProcesses {
    param([int]$GraceSeconds = 6, [int]$Attempts = 3)

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $processes = @(Get-TraditionalEdgeProcesses)
        if ($processes.Count -eq 0) {
            if ($attempt -eq 1) { Write-Log 'No traditional Edge browser processes are running.' }
            else { Write-Log 'Traditional Edge processes have been stopped.' 'OK' }
            return
        }

        Write-Log ("Automatically closing traditional Edge process(es), attempt {0}/{1}: PID(s) {2}" -f $attempt, $Attempts, (($processes | ForEach-Object { $_.ProcessId }) -join ', ')) 'WARN'

        # First ask visible browser windows to close normally. This gives the browser
        # a short opportunity to flush its profile and close cleanly.
        foreach ($item in $processes) {
            try {
                $process = Get-Process -Id ([int]$item.ProcessId) -ErrorAction Stop
                if ($process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() }
            } catch {
                Add-RemovalFinding -Severity 'Moderate' -Stage 'BrowserClose' -Target ("msedge.exe PID {0}" -f $item.ProcessId) -Message $_.Exception.Message -ImpactZh '无法正常请求浏览器自行关闭。若继续，工具会尝试强制结束已确认属于传统 Edge 的进程；未保存内容可能丢失。' -ImpactEn 'A graceful close could not be requested. If you continue, the tool will attempt to force-stop the confirmed traditional Edge process; unsaved content may be lost.'
            }
        }
        if ($GraceSeconds -gt 0) { Start-Sleep -Seconds $GraceSeconds }
        Confirm-RemovalContinuation -Stage 'BrowserClose'

        # Force-stop only processes whose executable path is confirmed as Edge's
        # desktop browser. This deliberately does not target msedgewebview2.exe.
        $remaining = @(Get-TraditionalEdgeProcesses)
        foreach ($item in $remaining) {
            try {
                Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction Stop
                Write-Log ("Force-stopped traditional Edge PID {0}" -f $item.ProcessId) 'WARN'
            } catch {
                Write-Log ("Could not stop traditional Edge PID {0}: {1}" -f $item.ProcessId, $_.Exception.Message) 'ERROR'
            }
        }
        Start-Sleep -Seconds 1
    }

    $left = @(Get-TraditionalEdgeProcesses)
    if ($left.Count -gt 0) {
        $pidList = ($left | ForEach-Object { '{0} ({1})' -f $_.ProcessId, $_.ExecutablePath }) -join '; '
        Write-Log ("Edge processes remain after automatic close attempts: $pidList. Aborting before backup/removal.") 'ERROR'
        throw 'The tool could not automatically stop all traditional Edge processes. No backup or cleanup was started.'
    }
    Write-Log 'Traditional Edge browser processes were stopped automatically.' 'OK'
}

function Get-EdgeUpdateProcesses {
    # Only match processes running from the updater's own directory. WebView2 uses
    # Microsoft\EdgeWebView and msedgewebview2.exe, neither of which is targeted here.
    try {
        $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        throw "Could not enumerate processes before Edge Update cleanup; refusing to delete updater files. $($_.Exception.Message)"
    }

    $knownUpdaterNames = @($allProcesses | Where-Object {
        [string]$_.Name -match '^(?i:MicrosoftEdgeUpdate|MicrosoftEdgeUpdateCore|MicrosoftEdgeUpdateBroker)\.exe$'
    })
    $unresolved = @($knownUpdaterNames | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) })
    if ($unresolved.Count -gt 0) {
        $ids = ($unresolved | ForEach-Object { [string]$_.ProcessId }) -join ', '
        throw "Cannot verify the executable path for Edge Update process PID(s) $ids; refusing to proceed with updater-file deletion."
    }

    return @($allProcesses | Where-Object {
        $_.ExecutablePath -and [string]$_.ExecutablePath -match '(?i)\\Microsoft\\EdgeUpdate(?:\\|$)'
    })
}

function Stop-EdgeUpdateProcesses {
    param([int]$Attempts = 3)

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $processes = @(Get-EdgeUpdateProcesses)
        if ($processes.Count -eq 0) {
            if ($attempt -eq 1) { Write-Log 'No Edge Update processes are running.' }
            else { Write-Log 'All verified Edge Update processes have stopped.' 'OK' }
            return
        }

        Write-Log ("Stopping verified Edge Update process(es), attempt {0}/{1}: {2}" -f $attempt, $Attempts, (($processes | ForEach-Object { '{0} PID {1} ({2})' -f $_.Name, $_.ProcessId, $_.ExecutablePath }) -join '; ')) 'WARN'
        foreach ($processInfo in $processes) {
            try {
                Stop-Process -Id ([int]$processInfo.ProcessId) -Force -ErrorAction Stop
                Write-Log ("Stopped Edge Update process PID {0}: {1}" -f $processInfo.ProcessId, $processInfo.ExecutablePath) 'OK'
            } catch {
                Write-Log ("Could not stop Edge Update process PID {0}: {1}" -f $processInfo.ProcessId, $_.Exception.Message) 'WARN'
            }
        }
        Start-Sleep -Seconds 1
    }

    $remaining = @(Get-EdgeUpdateProcesses)
    if ($remaining.Count -gt 0) {
        $details = ($remaining | ForEach-Object { '{0} PID {1} ({2})' -f $_.Name, $_.ProcessId, $_.ExecutablePath }) -join '; '
        throw "Edge Update process(es) are still running after stop attempts: $details. Updater directories will not be deleted; the recovery backup will be retained."
    }
    Write-Log 'All verified Edge Update processes have stopped.' 'OK'
}

function Test-EdgeUpdateQuiescent {
    # A user may accept ordinary warnings, but cannot override this safety precondition.
    $serviceRecords = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
        ([string]$_.Name -match '^(?i:edgeupdate|edgeupdatem|MicrosoftEdgeElevationService)$') -or
        ([string]$_.DisplayName -match '(?i)Microsoft Edge Update|Microsoft Edge Elevation')
    })
    foreach ($serviceRecord in $serviceRecords) {
        if ([string]$serviceRecord.State -ine 'Stopped' -or [string]$serviceRecord.StartMode -ine 'Disabled') {
            throw "Edge-related service is not quiescent: $($serviceRecord.Name) (State=$($serviceRecord.State), StartMode=$($serviceRecord.StartMode)). Refusing to remove Edge Update files."
        }
    }

    $remainingTasks = @(Get-EdgeTasks)
    if ($remainingTasks.Count -gt 0) {
        $taskDetails = ($remainingTasks | ForEach-Object { '{0}{1}' -f $_.TaskPath, $_.TaskName }) -join '; '
        throw "Edge Update scheduled task(s) remain registered after removal attempts: $taskDetails. Refusing to remove Edge Update files."
    }

    $remainingProcesses = @(Get-EdgeUpdateProcesses)
    if ($remainingProcesses.Count -gt 0) {
        $processDetails = ($remainingProcesses | ForEach-Object { '{0} PID {1} ({2})' -f $_.Name, $_.ProcessId, $_.ExecutablePath }) -join '; '
        throw "Edge Update process(es) remain: $processDetails. Refusing to remove Edge Update files."
    }
    Write-Log 'Edge Update services are disabled/stopped, update tasks are absent, and updater processes are stopped.' 'OK'
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
                if ($p.ExitCode -eq 0) {
                    Write-Log "Uninstaller exit code: 0 for $($setup.FullName)" 'OK'
                } elseif ($p.ExitCode -eq 93) {
                    # In this forced-removal workflow, exit code 93 has repeatedly been observed
                    # when the official Edge uninstaller refuses the requested uninstall. Treat it
                    # as an expected hand-off to direct cleanup; final residual verification remains decisive.
                    Write-Log "Official Edge uninstaller returned the known forced-removal response code 93 for $($setup.FullName); proceeding to direct cleanup and independent final verification." 'INFO'
                } else {
                    Add-RemovalFinding -Severity 'Moderate' -Stage 'Uninstaller' -Target $setup.FullName -Message ("Uninstaller returned exit code {0}." -f $p.ExitCode) -ImpactZh '官方卸载器返回非预期退出码；工具会显示影响并等待你决定是否继续，最终仍会核验清理结果。' -ImpactEn 'The official uninstaller returned an unexpected exit code. The tool will ask whether to continue, then independently verify cleanup if accepted.'
                }
            } catch {
                Add-RemovalFinding -Severity 'Moderate' -Stage 'Uninstaller' -Target $setup.FullName -Message $_.Exception.Message -ImpactZh '官方卸载器无法正常运行；后续手动清理仍会尝试执行，但可能留下残留。' -ImpactEn 'The official uninstaller could not run normally. Manual cleanup will still be attempted, but residue may remain.'
            }
        }
    }
}

function Remove-Edge {
    $script:RemovalFindings = New-Object 'System.Collections.Generic.List[object]'
    Write-Log 'Starting Edge removal workflow. One confirmation starts preparation; successful backup validation proceeds directly to removal. WebView2 is excluded.'
    $startupState = $null
    $startupAdjustmentsAttempted = $false
    $backupDir = $null
    $previousLatestBackup = $null
    $pointerPath = Join-Path $script:BackupRoot 'latest-backup.txt'

    try {
        if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
            $previousLatestBackup = (Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
            if ($previousLatestBackup.Length -gt 0 -and $previousLatestBackup[0] -eq [char]0xFEFF) {
                $previousLatestBackup = $previousLatestBackup.Substring(1).Trim()
            }
        }
        $startupState = Get-EdgeStartupState
        $backupDir = New-BackupStagingDirectory
        $startupStatePath = Join-Path $backupDir 'startup-state.json'
        $startupState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $startupStatePath -Encoding UTF8 -ErrorAction Stop
        Write-Log "Saved original Edge startup state before changes: $startupStatePath" 'OK'

        $startupAdjustmentsAttempted = $true
        Disable-EdgeStartupMechanisms -State $startupState
        Stop-TraditionalEdgeProcesses -GraceSeconds 2 -Attempts 4
        foreach ($setting in @($startupState.PreferenceValues)) {
            if (-not (Test-Path -LiteralPath $setting.Path)) {
                New-Item -Path $setting.Path -Force -ErrorAction Stop | Out-Null
            }
            New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            $verifiedPreference = Get-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -ErrorAction Stop
            $verifiedPreferenceValue = $verifiedPreference.PSObject.Properties[[string]$setting.Name].Value
            if ([int]$verifiedPreferenceValue -ne 0) {
                throw "Edge startup preference was re-enabled while closing Edge: $($setting.Path)\$($setting.Name)"
            }
        }
        Remove-EdgeAutoLaunchRunValues
        Start-Sleep -Seconds 2
        $remainingEdge = @(Get-TraditionalEdgeProcesses)
        if ($remainingEdge.Count -gt 0) {
            throw 'Traditional Edge restarted after auto-start was disabled. No file backup or removal was started.'
        }
        Write-Log 'Edge startup controls disabled and no traditional Edge processes remain; beginning file/registry/task backup.' 'OK'
        $backupDir = New-PreRemovalBackup -BackupDirectory $backupDir -StartupState $startupState
    } catch {
        $preparationError = $_.Exception.Message
        $startupRestoreSucceeded = $true
        if ($startupAdjustmentsAttempted -and $startupState) {
            Write-Log 'Preparation/backup validation failed; restoring the original Edge startup settings and auto-launch values.' 'WARN'
            $startupRestoreSucceeded = [bool](Restore-EdgeStartupMechanisms -State $startupState)
        }
        if ($backupDir) {
            if ($startupRestoreSucceeded) {
                [void](Remove-CurrentRunBackup -BackupDirectory $backupDir -PreviousLatestBackup $previousLatestBackup)
            } else {
                Write-Log "The incomplete backup is retained at '$backupDir' because at least one original startup setting could not be restored." 'ERROR'
            }
        }
        throw $preparationError
    }

    Write-Host (Get-UiText 'BackupComplete') -ForegroundColor Green
    Write-Host (Get-UiText 'BackupLocation') -ForegroundColor Cyan
    Write-Host $backupDir -ForegroundColor Cyan
    if ($script:EnableRemovalExecution) {
        Write-Host (Get-UiText 'BackupAutoContinue') -ForegroundColor Yellow
    } else {
        Write-Host (Get-UiText 'BackupSafetyGateNotice') -ForegroundColor Yellow
    }

    # The safety gate exists only in staged builds. A release build with the gate
    # disabled proceeds directly, without asking for a second confirmation.
    if (-not $script:EnableRemovalExecution) {
        Write-Log 'Destructive removal blocked by the staged-build safety gate. The validated backup is intentionally retained for testing.' 'WARN'
        $startupRestored = [bool](Restore-EdgeStartupMechanisms -State $startupState)
        if ($startupRestored) {
            Write-Log 'Original Edge startup settings and auto-launch values were restored because destructive removal is locked in this test build.' 'OK'
        } else {
            Write-Log "Some startup settings could not be restored. Keep the test backup for recovery: $backupDir" 'ERROR'
        }
        # Keep the staged backup for inspection, but do not leave latest-backup.txt
        # pointing at RemovalState=NotStarted. That would hide an older valid restore
        # backup because the restore selector intentionally refuses stale fallback.
        [void](Set-LatestRestoreEligibleBackupPointer -CurrentBackupDirectoryToExclude $backupDir -PreferredBackupDirectory $previousLatestBackup)
        Write-Host (Get-UiText 'RemovalBlockedStage') -ForegroundColor Yellow
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }

    $manifestPath = Join-Path $backupDir 'manifest.json'
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$manifest.BackupStatus -ne 'Complete' -or @($manifest.BackupWarnings).Count -gt 0) {
            throw 'The backup manifest is no longer in a valid Complete state.'
        }
        $manifest.RemovalState = 'InProgress'
        $manifest.RemovalStartedAt = (Get-Date).ToString('o')
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
        Write-Log 'Marked removal state InProgress in manifest before destructive actions.' 'OK'
    } catch {
        $stateMarkError = $_.Exception.Message
        Write-Log "Could not mark the validated backup as InProgress; removal will not start: $stateMarkError" 'ERROR'
        $startupRestoreSucceeded = [bool](Restore-EdgeStartupMechanisms -State $startupState)
        if ($startupRestoreSucceeded) {
            [void](Remove-CurrentRunBackup -BackupDirectory $backupDir -PreviousLatestBackup $previousLatestBackup)
        } else {
            Write-Log "Backup retained for recovery because startup restoration was incomplete: $backupDir" 'ERROR'
        }
        throw $stateMarkError
    }

    try {
    Stop-TraditionalEdgeProcesses -GraceSeconds 2
    Write-Log 'Stopped traditional Edge browser processes; WebView2 executable was not targeted.'

    foreach ($task in (Get-EdgeTasks)) {
        try {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Log "Removed Edge Update task: $($task.TaskPath)$($task.TaskName)" 'OK'
        } catch {
            Add-RemovalFinding -Severity 'Moderate' -Stage 'ScheduledTasks' -Target ("{0}{1}" -f $task.TaskPath, $task.TaskName) -Message $_.Exception.Message -ImpactZh 'Edge Update 计划任务可能仍存在并继续运行；浏览器文件清理仍可继续，但更新相关任务可能残留。' -ImpactEn 'The Edge Update scheduled task may remain and continue running. Browser-file cleanup can proceed, but updater-task residue may remain.'
        }
    }
    Confirm-RemovalContinuation -Stage 'ScheduledTasks'

    foreach ($svc in @(Get-EdgeServices)) {
        try {
            if ($svc.State -eq 'Running') { Stop-Service -Name $svc.Name -Force -ErrorAction Stop }
            Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
            Write-Log "Stopped and disabled Edge-related service before uninstall: $($svc.Name)" 'OK'
        } catch {
            Add-RemovalFinding -Severity 'Moderate' -Stage 'ServicePreparation' -Target $svc.Name -Message $_.Exception.Message -ImpactZh '该更新服务可能仍在运行或保持启用状态，可能影响后续文件删除或更新行为。' -ImpactEn 'The updater service may still be running or enabled, which can affect file removal or update behavior.'
        }
    }
    Confirm-RemovalContinuation -Stage 'ServicePreparation'
    # Do not continue if task/service shutdown merely produced warnings; prove quiescence.
    Stop-EdgeUpdateProcesses
    Test-EdgeUpdateQuiescent
    Invoke-EdgeUninstallers
    Confirm-RemovalContinuation -Stage 'Uninstaller'
    # Uninstaller first, then unregister the Edge-specific services. The service snapshot
    # is in the backup, and restore recreates the SCM registration if it is absent.
    foreach ($svc in @(Get-EdgeServices)) {
        try {
            $scOutput = & "$env:SystemRoot\System32\sc.exe" delete $svc.Name 2>&1
            $scCode = $LASTEXITCODE
            if ($scCode -ne 0) { throw "sc.exe delete returned exit code $scCode. $($scOutput -join ' ')" }
            Write-Log "Requested service registration deletion: $($svc.Name)" 'OK'
            Start-Sleep -Milliseconds 700
            $stillRegistered = @(Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $svc.Name.Replace("'", "''")) -ErrorAction Stop)
            if ($stillRegistered.Count -gt 0) {
                Add-RemovalFinding -Severity 'High' -Stage 'ServiceRemoval' -Target $svc.Name -Message 'Service remains registered or is pending deletion after sc.exe delete.' -ImpactZh 'Edge Update 服务可能仍然存在；它通常不决定浏览器主程序能否删除，但可能继续参与更新，残留会写入最终报告。' -ImpactEn 'The Edge Update service may remain. It does not always prevent browser removal, but updater behavior may remain and will be reported.'
            } else {
                Write-Log "Service registration no longer appears in Win32_Service: $($svc.Name)" 'OK'
            }
        } catch {
            Add-RemovalFinding -Severity 'High' -Stage 'ServiceRemoval' -Target $svc.Name -Message $_.Exception.Message -ImpactZh '无法确认或删除此服务注册；服务可能残留。若继续，工具会在最终核验中再次检查并保留恢复备份。' -ImpactEn 'The service registration could not be removed or verified and may remain. If you continue, final verification will check it again and the recovery backup will be retained if residue remains.'
        }
    }
    Confirm-RemovalContinuation -Stage 'ServiceRemoval'
    # The official uninstaller may restart an updater process. Sweep again before deleting files.
    Stop-EdgeUpdateProcesses
    Test-EdgeUpdateQuiescent
    try { Remove-EdgeAutoLaunchRunValues } catch {
        Add-RemovalFinding -Severity 'Moderate' -Stage 'AutoLaunch' -Target 'Edge auto-launch registry values' -Message $_.Exception.Message -ImpactZh '某个 Edge 自动启动项可能仍存在；这不一定阻止主程序删除，但可能在登录时尝试启动 Edge。' -ImpactEn 'An Edge auto-launch value may remain. This may not block browser removal, but Edge could attempt to launch at sign-in.'
    }
    Confirm-RemovalContinuation -Stage 'AutoLaunch'

    foreach ($p in (Get-EdgeShortcutTargets)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        Invoke-UnpinAttempt -ShortcutPath $p
        try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; Write-Log "Removed shortcut: $p" 'OK' }
        catch {
            Add-RemovalFinding -Severity 'Low' -Stage 'Shortcuts' -Target $p -Message $_.Exception.Message -ImpactZh '快捷方式可能仍会显示，但不代表浏览器主程序仍可运行。可继续清理其他组件。' -ImpactEn 'A shortcut may remain visible, but this does not necessarily mean the browser executable remains. Other components can still be cleaned.'
        }
    }
    Confirm-RemovalContinuation -Stage 'Shortcuts'

    # Remove Edge browser/profile and EdgeUpdate directories only after the updater was
    # quiesced and rechecked. Preserve the separate WebView2 runtime directory.
    foreach ($p in (Get-EdgeFileTargets)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if ($p -match '(?i)\\Microsoft\\EdgeWebView(\\|$)') {
            Write-Log "Protected WebView2 runtime directory: $p" 'WARN'; continue
        }
        try {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $p) {
                throw "Directory still exists after Remove-Item returned: $p"
            }
            Write-Log "Removed directory: $p" 'OK'
        }
        catch {
            # Edge Update still present is a hard stop: continuing to remove registry
            # registrations while its files remain could leave updater repair behavior active.
            if ($p -match '(?i)\\Microsoft\\EdgeUpdate$') {
                throw ("Edge Update directory could not be fully removed; stopping before registry cleanup and retaining the recovery backup. Path='{0}'. Cause: {1}" -f $p, $_.Exception.Message)
            }
            $remainingBrowserExecutable = @()
            if ($p -match '(?i)\\Microsoft\\Edge(?:Core)?$') {
                try {
                    $remainingBrowserExecutable = @(Get-ChildItem -LiteralPath $p -Filter 'msedge.exe' -File -Recurse -ErrorAction Stop | Select-Object -ExpandProperty FullName)
                } catch {
                    throw ("Could not verify whether the core browser executable remains under '{0}'. This is a hard blocker: {1}" -f $p, $_.Exception.Message)
                }
            }
            if ($remainingBrowserExecutable.Count -gt 0) {
                throw ("Core browser executable remains after failed directory removal: {0}. The essential removal result cannot be considered successful; cleanup is stopping and the backup will be retained." -f ($remainingBrowserExecutable -join '; '))
            }
            Add-RemovalFinding -Severity 'High' -Stage 'Directories' -Target $p -Message $_.Exception.Message -ImpactZh '目录可能仍有被占用或权限不足的非核心文件。若继续，工具会清理其他项目，并在最终核验中报告目录残留、保留备份。' -ImpactEn 'Non-core files may remain because of locks or access restrictions. If you continue, other targets will be cleaned and final verification will report any remaining directory and keep the backup.'
        }
    }
    Confirm-RemovalContinuation -Stage 'Directories'

    foreach ($key in (Get-RegistryTargets)) {
        try {
            $providerPath = ConvertTo-RegistryProviderPath $key
            if (Test-Path -LiteralPath $providerPath) {
                Remove-Item -LiteralPath $providerPath -Recurse -Force -ErrorAction Stop
                Write-Log "Removed browser registration: $key" 'OK'
            }
        } catch {
            Add-RemovalFinding -Severity 'Moderate' -Stage 'Registry' -Target $key -Message $_.Exception.Message -ImpactZh '此 Edge 注册表项可能残留，可能影响应用登记、默认浏览器关联或后续更新行为；文件清理仍可继续。' -ImpactEn 'This Edge registry key may remain and affect app registration, default-browser associations, or updater behavior. File cleanup can continue.'
        }
    }
    Confirm-RemovalContinuation -Stage 'Registry'

    # A surviving desktop-browser executable is an essential-effect failure, not a
    # user-overridable cosmetic residual. Stop before reporting this as completed.
    foreach ($edgeRoot in @(Get-EdgeFileTargets | Where-Object { $_ -match '(?i)\\Microsoft\\Edge$' })) {
        $mainExecutable = Join-Path $edgeRoot 'Application\msedge.exe'
        if (Test-Path -LiteralPath $mainExecutable -PathType Leaf) {
            throw ("Core browser executable remains after cleanup: {0}. The essential removal result failed; the backup will be retained." -f $mainExecutable)
        }
    }

    $residuals = New-Object 'System.Collections.Generic.List[string]'
    $intentional = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in (Get-EdgeFileTargets)) { if (Test-Path -LiteralPath $p) { $residuals.Add("Directory remains: $p") } }
    foreach ($p in (Get-EdgeShortcutTargets)) { if (Test-Path -LiteralPath $p) { $residuals.Add("Shortcut remains: $p") } }
    foreach ($svc in @(Get-EdgeServices)) {
        $residuals.Add("Edge-related service registration remains: $($svc.Name) (StartMode=$($svc.StartMode), State=$($svc.State)); it may be pending deletion until reboot or was not removable")
    }
    foreach ($task in (Get-EdgeTasks)) { $residuals.Add("Edge Update task remains: $($task.TaskPath)$($task.TaskName)") }
    foreach ($key in (Get-RegistryTargets)) { if (Test-NativeRegistryKey $key) { $residuals.Add("Registry key remains: $key") } }
    # The runtime directory and product registration are deliberately excluded from
    # removal targets. Record that policy explicitly instead of leaving this section empty.
    $intentional.Add('Microsoft Edge WebView2 Runtime files and product registration are intentionally preserved.')
    $intentional.Add('Microsoft Edge Update files/services are targeted; WebView2 automatic updates may consequently be affected.')

    $reportPath = Join-Path $backupDir 'removal-report.txt'
    $report = @(
        'WenZoo Edge Removal Tool - Removal Report',
        ('Date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('Computer: ' + $env:COMPUTERNAME),
        ('Backup: ' + $backupDir),
        '',
        'Notes:',
        '- WebView2 Runtime files and product registration are intentionally protected.',
        '- Edge Update program files are targeted for removal. This can disable automatic updates for WebView2 Runtime; the WebView2 runtime files and product registration are preserved.',
        '- Windows 11 Start/taskbar pin databases and OS-managed packages may not be fully controllable on every build.',
        '- A clean result does not guarantee Windows Update will never reinstall Edge.',
        '',
        'Intentionally retained / disabled components:'
    )
    if ($intentional.Count -eq 0) { $report += 'None detected.' } else { $report += @($intentional) }
    $report += ''; $report += 'Residuals / exceptions:'
    if ($residuals.Count -eq 0) {
        $report += 'No targeted residuals detected by the checks in this script.'
    } else {
        $report += @($residuals)
        Write-Host ''
        Write-Host (Get-UiText 'FinalResidualHeading') -ForegroundColor Yellow
        foreach ($residual in $residuals) {
            $residualSeverity = if ($residual -like 'Shortcut remains:*') { Get-UiText 'SeverityLow' } else { Get-UiText 'SeverityModerate' }
            Write-Host ("[{0}] {1}" -f $residualSeverity, $residual) -ForegroundColor Yellow
        }
        Write-Host (Get-UiText 'FinalResidualSafetyNote') -ForegroundColor Yellow
        $residualDecision = Read-Host (Get-UiText 'AcceptResidualsPrompt')
        if (-not [string]::Equals(([string]$residualDecision).Trim(), 'Y', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [System.OperationCanceledException]::new('User declined to accept residual items. Automatic rollback is required before temporary backup cleanup.')
        }
        Write-Log 'User accepted the best-effort result with known residual items; removal state will be CompletedWithResiduals and backup retained.' 'WARN'
    }
    $acceptedFindings = @($script:RemovalFindings | Where-Object { $_.UserAccepted })
    $report += ''; $report += 'Non-blocking exceptions explicitly accepted by the user:'
    if ($acceptedFindings.Count -eq 0) {
        $report += 'None.'
    } else {
        foreach ($finding in $acceptedFindings) {
            $report += ('[{0}] Stage={1}; Target={2}; Message={3}; Impact={4}' -f $finding.Severity, $finding.Stage, $finding.Target, $finding.Message, $finding.ImpactEn)
        }
    }
    Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8 -ErrorAction Stop
    $manifest.RemovalResults = @($residuals)
    $manifest.RemovalCompletedAt = (Get-Date).ToString('o')
    $manifest.RemovalState = if ($residuals.Count -eq 0) { 'Completed' } else { 'CompletedWithResiduals' }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
    if ($residuals.Count -eq 0) {
        Write-Log "Cleanup finished; no targeted residuals detected. Report: $reportPath" 'OK'
        Write-Log "Backup retained for restoration until the user decides whether to delete it: $backupDir" 'OK'
        Remove-Backups -AfterRemoval
    } else {
        Write-Log "Cleanup workflow ended with $($residuals.Count) residual/exception item(s). Backup has been retained for recovery. Review: $reportPath" 'WARN'
        Write-Host (Get-UiText 'RemovalResidualsBackupKept') -ForegroundColor Yellow
        Read-Host (Get-UiText 'PressEnter') | Out-Null
    }
    } catch {
        $removalError = $_.Exception.Message
        $userCancelled = ($_.Exception -is [System.OperationCanceledException])
        try {
            $failureManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $failureManifest.RemovalState = 'Partial'
            Set-ObjectPropertyValue -Object $failureManifest -Name 'RemovalFailedAt' -Value ((Get-Date).ToString('o'))
            $priorRemovalErrors = @()
            if ($failureManifest.PSObject.Properties['RemovalErrors']) { $priorRemovalErrors = @($failureManifest.RemovalErrors) }
            Set-ObjectPropertyValue -Object $failureManifest -Name 'RemovalErrors' -Value (@($priorRemovalErrors) + @($removalError))
            $failureManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Log "Could not persist partial-removal state to manifest; backup directory remains at '$backupDir'. Error: $($_.Exception.Message)" 'ERROR'
        }

        if ($userCancelled) {
            Write-Log "Removal cancelled by user at a continuation prompt: $removalError" 'WARN'
            Write-Log 'Automatic rollback is starting. The current-run backup will be deleted only after all restore checks pass.' 'WARN'
            $rollbackSucceeded = $false
            try {
                $rollbackSucceeded = [bool](Restore-PreRemovalState -BackupDirectory $backupDir -AutomaticRollback)
            } catch {
                Write-Log "Automatic rollback threw an exception; the recovery backup must be retained: $($_.Exception.Message)" 'ERROR'
                $rollbackSucceeded = $false
            }
            if ($rollbackSucceeded) {
                $backupDeleted = [bool](Remove-CurrentRunBackup -BackupDirectory $backupDir -PreviousLatestBackup $previousLatestBackup)
                if ($backupDeleted) {
                    Write-Log "User cancelled removal. Original files, registrations, services, tasks, and startup settings were restored and verified; this run's temporary backup was removed." 'OK'
                    Write-Host '已取消后续移除；原始状态已恢复并验证，本次临时备份已清理。' -ForegroundColor Green
                } else {
                    [void](Set-LatestRestoreEligibleBackupPointer -CurrentBackupDirectoryToExclude $backupDir -PreferredBackupDirectory $previousLatestBackup)
                    Write-Log "Original state was restored, but this run's backup could not be removed. It remains at '$backupDir'; it can be deleted from menu 3." 'WARN'
                    Write-Host "原始状态已恢复，但本次备份未能删除，仍保留于：$backupDir" -ForegroundColor Yellow
                }
            } else {
                Write-Log "Automatic rollback was incomplete. The backup is retained for manual recovery: $backupDir" 'ERROR'
                Write-Host "自动回滚未能完整验证；为避免丢失恢复资料，备份已保留：$backupDir" -ForegroundColor Red
            }
            return
        }

        Write-Log "Removal did not complete cleanly. The backup will be retained for recovery: $removalError" 'ERROR'
        throw $removalError
    }
}

function Test-BackupManifestEligible {
    param([Parameter(Mandatory=$true)][string]$BackupDirectory)
    $manifestPath = Join-Path $BackupDirectory 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($manifest.PSObject.Properties['BackupStatus']) {
            return ([string]$manifest.BackupStatus -eq 'Complete' -and @($manifest.BackupWarnings).Count -eq 0)
        }
        # Backward compatibility for prior schema-2 backups: require zero warnings and
        # a complete file-entry validation record before allowing restore.
        if (@($manifest.BackupWarnings).Count -gt 0 -or -not $manifest.BackupValidation) { return $false }
        return ([int]$manifest.BackupValidation.FileEntriesRecorded -eq [int]$manifest.BackupValidation.FileEntriesValidated)
    } catch {
        return $false
    }
}

function Test-BackupRestoreEligible {
    param([Parameter(Mandatory=$true)][string]$BackupDirectory)
    if (-not (Test-BackupManifestEligible -BackupDirectory $BackupDirectory)) { return $false }
    try {
        $manifestPath = Join-Path $BackupDirectory 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        # A backup created and then cancelled must never be mirrored back over the live
        # browser profile. Only an explicit record that the destructive phase started
        # makes it eligible for automatic restoration.
        if ([string]$manifest.RemovalState -notin @('InProgress','Completed','CompletedWithResiduals','Partial','Failed')) { return $false }
        foreach ($entry in @($manifest.FileEntries)) {
            if ($entry.IsDirectory) {
                if (-not $entry.BackupInventory -or [string]$entry.BackupInventory.HashAlgorithm -ne 'SHA256') { return $false }
            } else {
                if ($null -eq $entry.BackupLength -or [string]::IsNullOrWhiteSpace([string]$entry.BackupHash)) { return $false }
            }
        }
        foreach ($groupName in @('RegistryEntries', 'RegistrySnapshots', 'Tasks')) {
            foreach ($entry in @($manifest.$groupName)) {
                if ($null -eq $entry.BackupLength -or [string]::IsNullOrWhiteSpace([string]$entry.BackupHash)) { return $false }
            }
        }
        foreach ($svc in @($manifest.Services)) {
            if ([string]::IsNullOrWhiteSpace([string]$svc.Name) -or
                [string]::IsNullOrWhiteSpace([string]$svc.PathName) -or
                [string]::IsNullOrWhiteSpace([string]$svc.SecurityDescriptor)) { return $false }
            $expectedServiceKey = 'HKLM\SYSTEM\CurrentControlSet\Services\' + [string]$svc.Name
            $serviceSnapshots = @($manifest.RegistrySnapshots | Where-Object {
                [string]$_.NativePath -ieq $expectedServiceKey
            })
            if ($serviceSnapshots.Count -ne 1) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-LatestBackupDirectory {
    $pointer = Join-Path $script:BackupRoot 'latest-backup.txt'
    if (Test-Path -LiteralPath $pointer) {
        $candidate = (Get-Content -LiteralPath $pointer -Raw -Encoding UTF8).Trim()
        if ($candidate.Length -gt 0 -and $candidate[0] -eq [char]0xFEFF) { $candidate = $candidate.Substring(1).Trim() }
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            $candidateManifest = Join-Path $candidate 'manifest.json'
            if (Test-Path -LiteralPath $candidateManifest -PathType Leaf) {
                if (Test-BackupRestoreEligible -BackupDirectory $candidate) { return $candidate }
                # Never fall back to an older completed backup when the latest recorded
                # backup is cancelled, not started, already restored, or otherwise ineligible.
                # This prevents restoring stale browser data over the live user profile.
                Write-Log "The latest backup pointer is not restore-eligible: $candidate. Refusing to fall back to an older backup." 'WARN'
                return $null
            }
        }
    }
    # Fallback is only for a missing/stale pointer target, never for a present but ineligible manifest.
    $latest = Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-BackupRestoreEligible -BackupDirectory $_.FullName } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { return $latest.FullName }
    return $null
}

function Restore-PreRemovalState {
    param(
        [string]$BackupDirectory,
        [switch]$AutomaticRollback
    )

    if ($AutomaticRollback) {
        if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
            Write-Log 'Automatic rollback was requested without an explicit current-run backup path.' 'ERROR'
            return $false
        }
        $backupDir = [IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\')
        if (-not (Test-BackupRestoreEligible -BackupDirectory $backupDir)) {
            Write-Log "Automatic rollback refused because the current-run backup is not restore-eligible: $backupDir" 'ERROR'
            return $false
        }
        Write-Log "Starting automatic rollback from the current run's verified backup: $backupDir" 'WARN'
    } else {
        $backupDir = Get-LatestBackupDirectory
    }

    if (-not $backupDir) {
        Write-Log 'No restore-eligible backup found. Cancelled/legacy backups or backups without persisted SHA-256 inventories are not restored, to avoid overwriting live Edge data.' 'WARN'
        Write-Host (Get-UiText 'NoRestorableBackup') -ForegroundColor Yellow
        if ($AutomaticRollback) { return $false }
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }
    if (-not $AutomaticRollback) {
        Write-Host ((Get-UiText 'SelectedBackup') + ": $backupDir") -ForegroundColor Cyan
        Write-Host (Get-UiText 'RestoreWarning') -ForegroundColor Yellow
        $confirm = Read-Host (Get-UiText 'ConfirmRestore')
        if (-not [string]::Equals(([string]$confirm).Trim(), 'Y', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Log 'Restore cancelled by user.' 'WARN'
            Write-Host (Get-UiText 'RestoreCancelled') -ForegroundColor Yellow
            Read-Host (Get-UiText 'PressEnter') | Out-Null
            return
        }
    }
    try {
        $manifest = Get-Content -LiteralPath (Join-Path $backupDir 'manifest.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "Backup manifest is unreadable: $($_.Exception.Message)" 'ERROR'
        if ($AutomaticRollback) { return $false }
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }
    if ($manifest.ComputerName -and $manifest.ComputerName -ne $env:COMPUTERNAME) {
        Write-Log "Backup belongs to another computer ($($manifest.ComputerName)); refusing automatic restore." 'ERROR'
        if ($AutomaticRollback) { return $false }
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }
    # StartupState contains HKCU paths for the account that created this backup.
    # Restoring under another administrator would otherwise modify that administrator's
    # profile rather than the original user's profile, so refuse cross-account restore.
    $backupUser = if ($manifest.StartupState) { [string]$manifest.StartupState.UserName } else { '' }
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if (-not [string]::IsNullOrWhiteSpace($backupUser) -and $backupUser -ine $currentUser) {
        Write-Log "Backup belongs to Windows account '$backupUser', but the current account is '$currentUser'. Refusing restore to avoid changing the wrong HKCU profile." 'ERROR'
        if ($AutomaticRollback) { return $false }
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }

    # Complete preflight before touching any live files, registry keys, services, or tasks.
    try {
        foreach ($entry in @($manifest.FileEntries)) {
            [void](Test-PersistedBackupEntryIntegrity -Entry $entry)
        }
        foreach ($groupName in @('RegistryEntries', 'RegistrySnapshots', 'Tasks')) {
            foreach ($entry in @($manifest.$groupName)) {
                if (-not (Test-Path -LiteralPath $entry.BackupFile -PathType Leaf)) {
                    throw "Required $groupName backup file is missing: $($entry.BackupFile)"
                }
                $auxFile = Get-Item -LiteralPath $entry.BackupFile -ErrorAction Stop
                if ($null -eq $entry.BackupLength -or [long]$auxFile.Length -ne [long]$entry.BackupLength) {
                    throw "Backup length mismatch for $groupName file: $($entry.BackupFile)"
                }
                if ([string]::IsNullOrWhiteSpace([string]$entry.BackupHash)) {
                    throw "Backup hash missing for $groupName file: $($entry.BackupFile)"
                }
                $auxHash = (Get-FileHash -LiteralPath $entry.BackupFile -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($auxHash -cne [string]$entry.BackupHash) {
                    throw "Backup SHA-256 mismatch for $groupName file: $($entry.BackupFile)"
                }
                if ($groupName -ne 'Tasks') {
                    $header = Get-Content -LiteralPath $entry.BackupFile -TotalCount 1 -ErrorAction Stop
                    if ([string]$header -notmatch 'Windows Registry Editor Version 5\.00') {
                        throw "Invalid registry export header: $($entry.BackupFile)"
                    }
                } else {
                    $xmlDocument = New-Object System.Xml.XmlDocument
                    $xmlDocument.Load([string]$entry.BackupFile)
                    if ($xmlDocument.DocumentElement.LocalName -ne 'Task') {
                        throw "Invalid scheduled-task XML root: $($entry.BackupFile)"
                    }
                }
            }
        }
        foreach ($svc in @($manifest.Services)) {
            if ([string]::IsNullOrWhiteSpace([string]$svc.Name)) { throw 'Service record has no name.' }
            if ([string]::IsNullOrWhiteSpace([string]$svc.PathName)) { throw "Service recovery metadata is missing PathName for $($svc.Name)." }
            if ([string]::IsNullOrWhiteSpace([string]$svc.SecurityDescriptor)) { throw "Service recovery metadata is missing SecurityDescriptor for $($svc.Name)." }
            $expectedServiceKey = 'HKLM\SYSTEM\CurrentControlSet\Services\' + [string]$svc.Name
            $serviceSnapshots = @($manifest.RegistrySnapshots | Where-Object {
                [string]$_.NativePath -ieq $expectedServiceKey
            })
            if ($serviceSnapshots.Count -ne 1) {
                throw "Exactly one service registry snapshot is required for $($svc.Name); found $($serviceSnapshots.Count)."
            }
        }
    } catch {
        Write-Log "Restore preflight failed before any live changes: $($_.Exception.Message)" 'ERROR'
        if ($AutomaticRollback) { return $false }
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }

    # Disable the currently active startup mechanisms and stop the desktop browser before mirroring profile files.
    $currentStartupState = $null
    try {
        $currentStartupState = Get-EdgeStartupState
        Disable-EdgeStartupMechanisms -State $currentStartupState
        Stop-TraditionalEdgeProcesses -GraceSeconds 2 -Attempts 4
    } catch {
        if ($currentStartupState) { [void](Restore-EdgeStartupMechanisms -State $currentStartupState) }
        Write-Log "Restore aborted before file changes because Edge could not be stopped safely: $($_.Exception.Message)" 'ERROR'
        if ($AutomaticRollback) { return $false }
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }

    $restoreErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in @($manifest.FileEntries | Where-Object { $_ })) {
        try {
            if ($entry.IsDirectory) {
                Invoke-Robocopy -Source $entry.BackupPath -Destination $entry.OriginalPath -Mirror
            } else {
                $parent = Split-Path $entry.OriginalPath -Parent
                New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
                Copy-Item -LiteralPath $entry.BackupPath -Destination $entry.OriginalPath -Force -ErrorAction Stop
            }
            [void](Test-RestoredFileEntryIntegrity -Entry $entry)
            Write-Log "Restored and SHA-256 verified: $($entry.OriginalPath)" 'OK'
            if ($entry.OriginalPath -match '(?i)User Pinned\\(?:TaskBar|StartMenu)') { Invoke-PinAttempt -ShortcutPath $entry.OriginalPath }
        } catch {
            $message = "Could not restore '$($entry.OriginalPath)': $($_.Exception.Message)"
            $restoreErrors.Add($message)
            Write-Log $message 'ERROR'
        }
    }

    foreach ($entry in @($manifest.RegistryEntries)) {
        try {
            & reg.exe import $entry.BackupFile 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg.exe import exit code $LASTEXITCODE" }
            Write-Log "Restored registry key: $($entry.NativePath)" 'OK'
        } catch {
            $message = "Could not restore registry key '$($entry.NativePath)': $($_.Exception.Message)"
            $restoreErrors.Add($message)
            Write-Log $message 'ERROR'
        }
    }

    # Restore non-service snapshots first. Service snapshots are imported only after SCM
    # recognizes (or recreates) the corresponding service registration.
    foreach ($entry in @($manifest.RegistrySnapshots)) {
        if ([string]$entry.NativePath -match '(?i)^HKLM\\SYSTEM\\CurrentControlSet\\Services\\[^\\]+$') { continue }
        try {
            & reg.exe import $entry.BackupFile 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg.exe import exit code $LASTEXITCODE" }
            Write-Log "Restored registry snapshot: $($entry.NativePath)" 'OK'
        } catch {
            $message = "Could not restore registry snapshot '$($entry.NativePath)': $($_.Exception.Message)"
            $restoreErrors.Add($message)
            Write-Log $message 'ERROR'
        }
    }

    foreach ($svc in @($manifest.Services)) {
        try {
            $serviceQuery = @(Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f ([string]$svc.Name).Replace("'", "''")) -ErrorAction Stop)
            if ($serviceQuery.Count -gt 1) {
                throw "Service lookup returned multiple Win32_Service records for $($svc.Name); refusing ambiguous restoration."
            }
            $existingService = if ($serviceQuery.Count -eq 1) { $serviceQuery[0] } else { $null }
            if ($existingService -and [string]$existingService.State -eq 'Running') {
                Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            }
            if (-not $existingService) {
                $serviceTypeCode = switch -Regex ([string]$svc.ServiceType) {
                    '^Own Process$' { 16; break }
                    '^Share Process$' { 32; break }
                    default { throw "Unsupported saved service type '$($svc.ServiceType)' for $($svc.Name)." }
                }
                $errorControlCode = switch -Regex ([string]$svc.ErrorControl) {
                    '^Ignore$' { 0; break }
                    '^Normal$' { 1; break }
                    '^Severe$' { 2; break }
                    '^Critical$' { 3; break }
                    default { throw "Unsupported saved ErrorControl '$($svc.ErrorControl)' for $($svc.Name)." }
                }
                $wmiStartMode = switch -Regex ([string]$svc.StartMode) {
                    '^Auto$' { 'Automatic'; break }
                    '^Manual$' { 'Manual'; break }
                    '^Disabled$' { 'Disabled'; break }
                    default { throw "Unsupported saved StartMode '$($svc.StartMode)' for $($svc.Name)." }
                }
                # WMI Create receives PathName as one string, avoiding sc.exe parsing/quoting
                # problems for paths under "Program Files (x86)" and service command-line switches.
                $serviceClass = [wmiclass]"\\.\root\cimv2:Win32_Service"
                $serviceStartName = if ([string]::IsNullOrWhiteSpace([string]$svc.StartName)) { $null } else { [string]$svc.StartName }
                $createResult = $null
                $wmiReturnCode = $null
                try {
                    $createResult = $serviceClass.Create(
                        [string]$svc.Name,
                        [string]$svc.DisplayName,
                        [string]$svc.PathName,
                        [byte]$serviceTypeCode,
                        [byte]$errorControlCode,
                        [string]$wmiStartMode,
                        [bool]$false,
                        $serviceStartName,
                        $null,
                        $null,
                        $null,
                        $null
                    )
                    if ($createResult) { $wmiReturnCode = [uint32]$createResult.ReturnValue }
                } catch {
                    Write-Log "Win32_Service.Create threw for '$($svc.Name)': $($_.Exception.Message). Trying the Service Control Manager fallback." 'WARN'
                }

                # Win32_Service.Create may reject otherwise valid existing service metadata
                # on some Windows builds (ReturnValue=21). Try an explicit sc.exe create with
                # argument boundaries matching sc.exe's documented token grammar. The saved
                # service registry snapshot and security descriptor are applied and verified
                # immediately afterwards, so this is only a registration-creation fallback.
                $serviceCreateVerified = $false
                for ($createAttempt = 0; $createAttempt -lt 10; $createAttempt++) {
                    $createdServiceQuery = @(Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f ([string]$svc.Name).Replace("'", "''")) -ErrorAction Stop)
                    if ($createdServiceQuery.Count -eq 1) { $serviceCreateVerified = $true; break }
                    if ($createdServiceQuery.Count -gt 1) { throw "Service lookup returned multiple records after recreating $($svc.Name)." }
                    Start-Sleep -Milliseconds 300
                }
                if (-not $serviceCreateVerified) {
                    Write-Log "Win32_Service.Create did not register '$($svc.Name)' (ReturnValue=$wmiReturnCode); trying sc.exe create fallback." 'WARN'
                    $scType = switch ([int]$serviceTypeCode) { 16 { 'own' } 32 { 'share' } default { throw "Unsupported service type code $serviceTypeCode for $($svc.Name)." } }
                    $scError = switch ([int]$errorControlCode) { 0 { 'ignore' } 1 { 'normal' } 2 { 'severe' } 3 { 'critical' } default { throw "Unsupported ErrorControl code $errorControlCode for $($svc.Name)." } }
                    $scStart = switch ([string]$wmiStartMode) { 'Automatic' { 'auto' } 'Manual' { 'demand' } 'Disabled' { 'disabled' } default { throw "Unsupported startup mode '$wmiStartMode' for $($svc.Name)." } }
                    $scArgs = New-Object 'System.Collections.Generic.List[string]'
                    [void]$scArgs.Add('create')
                    [void]$scArgs.Add([string]$svc.Name)
                    [void]$scArgs.Add('binPath=')
                    [void]$scArgs.Add([string]$svc.PathName)
                    [void]$scArgs.Add('type=')
                    [void]$scArgs.Add($scType)
                    [void]$scArgs.Add('start=')
                    [void]$scArgs.Add($scStart)
                    [void]$scArgs.Add('error=')
                    [void]$scArgs.Add($scError)
                    if (-not [string]::IsNullOrWhiteSpace([string]$svc.StartName)) {
                        [void]$scArgs.Add('obj=')
                        [void]$scArgs.Add([string]$svc.StartName)
                    }
                    [void]$scArgs.Add('DisplayName=')
                    [void]$scArgs.Add([string]$svc.DisplayName)
                    $scArgArray = $scArgs.ToArray()
                    $scOutput = @(& "$env:SystemRoot\System32\sc.exe" @scArgArray 2>&1)
                    $scExitCode = $LASTEXITCODE
                    if ($scExitCode -ne 0) {
                        throw "Both service creation methods failed for $($svc.Name). Win32_Service.Create ReturnValue=$wmiReturnCode; sc.exe create exit code=$scExitCode; output=$($scOutput -join ' ')"
                    }
                    for ($createAttempt = 0; $createAttempt -lt 10; $createAttempt++) {
                        $createdServiceQuery = @(Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f ([string]$svc.Name).Replace("'", "''")) -ErrorAction Stop)
                        if ($createdServiceQuery.Count -eq 1) { $serviceCreateVerified = $true; break }
                        if ($createdServiceQuery.Count -gt 1) { throw "Service lookup returned multiple records after sc.exe created $($svc.Name)." }
                        Start-Sleep -Milliseconds 300
                    }
                }
                if (-not $serviceCreateVerified) { throw "Service creation did not produce a visible Service Control Manager registration for $($svc.Name)." }
                Write-Log "Created service registration and confirmed it is visible: $($svc.Name)" 'OK'
            }
            $serviceSnapshot = @($manifest.RegistrySnapshots | Where-Object { [string]$_.NativePath -ieq ("HKLM\SYSTEM\CurrentControlSet\Services\{0}" -f [string]$svc.Name) } | Select-Object -First 1)
            if ($serviceSnapshot.Count -gt 0) {
                & reg.exe import $serviceSnapshot[0].BackupFile 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Service registry snapshot import exit code $LASTEXITCODE for $($svc.Name)" }
            } else {
                throw "Service registry snapshot is missing for $($svc.Name)"
            }
            $sdOutput = & "$env:SystemRoot\System32\sc.exe" sdset $svc.Name ([string]$svc.SecurityDescriptor) 2>&1
            if ($LASTEXITCODE -ne 0) { throw "sc.exe sdset failed for $($svc.Name): $($sdOutput -join ' ')" }
            $sdVerifyOutput = @(& "$env:SystemRoot\System32\sc.exe" sdshow $svc.Name 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "sc.exe sdshow verification failed for $($svc.Name)." }
            $sdVerifyLine = @($sdVerifyOutput | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^D:' } | Select-Object -First 1)
            if ($sdVerifyLine.Count -ne 1 -or [string]$sdVerifyLine[0] -cne [string]$svc.SecurityDescriptor) {
                throw "Service security descriptor verification failed for $($svc.Name)."
            }
            $startup = switch -Regex ([string]$svc.StartMode) { '^Auto' {'Automatic'} '^Manual$' {'Manual'} '^Disabled$' {'Disabled'} default {'Manual'} }
            Set-Service -Name $svc.Name -StartupType $startup -ErrorAction Stop
            if ($svc.WasRunning) { Start-Service -Name $svc.Name -ErrorAction Stop }
            else {
                $stateNow = Get-Service -Name $svc.Name -ErrorAction Stop
                if ($stateNow.Status -eq 'Running') { Stop-Service -Name $svc.Name -Force -ErrorAction Stop }
            }
            $verifyServiceQuery = @()
            for ($verifyAttempt = 0; $verifyAttempt -lt 10; $verifyAttempt++) {
                $verifyServiceQuery = @(Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f ([string]$svc.Name).Replace("'", "''")) -ErrorAction Stop)
                if ($verifyServiceQuery.Count -ne 1) { throw "Service verification expected one record for $($svc.Name), found $($verifyServiceQuery.Count)." }
                $expectedState = if ($svc.WasRunning) { 'Running' } else { 'Stopped' }
                if ([string]$verifyServiceQuery[0].State -ieq $expectedState) { break }
                Start-Sleep -Milliseconds 500
            }
            $verifiedService = $verifyServiceQuery[0]
            $expectedMode = switch -Regex ([string]$svc.StartMode) { '^Auto' {'Auto'} '^Manual$' {'Manual'} '^Disabled$' {'Disabled'} default {'Manual'} }
            if ([string]$verifiedService.StartMode -ine $expectedMode) {
                throw "Service start mode verification failed for $($svc.Name): expected $expectedMode, found $($verifiedService.StartMode)."
            }
            if ([string]$verifiedService.DisplayName -ine [string]$svc.DisplayName) {
                throw "Service display-name verification failed for $($svc.Name)."
            }
            if ([string]$verifiedService.PathName -ine [string]$svc.PathName) {
                throw "Service executable path verification failed for $($svc.Name)."
            }
            if ([string]$verifiedService.ServiceType -ine [string]$svc.ServiceType) {
                throw "Service type verification failed for $($svc.Name): expected $($svc.ServiceType), found $($verifiedService.ServiceType)."
            }
            if ([string]$verifiedService.ErrorControl -ine [string]$svc.ErrorControl) {
                throw "Service ErrorControl verification failed for $($svc.Name): expected $($svc.ErrorControl), found $($verifiedService.ErrorControl)."
            }
            if ((-not [string]::IsNullOrWhiteSpace([string]$svc.StartName)) -and ([string]$verifiedService.StartName -ine [string]$svc.StartName)) {
                throw "Service logon account verification failed for $($svc.Name)."
            }
            if ([string]$verifiedService.State -ine $expectedState) {
                throw "Service state verification failed for $($svc.Name): expected $expectedState, found $($verifiedService.State)."
            }
            Write-Log "Restored and verified service: $($svc.Name) (StartMode=$expectedMode, State=$expectedState, DisplayName, PathName, type, ErrorControl and account verified)" 'OK'
        } catch {
            $message = "Could not restore service '$($svc.Name)': $($_.Exception.Message)"
            $restoreErrors.Add($message)
            Write-Log $message 'ERROR'
        }
    }

    foreach ($task in @($manifest.Tasks)) {
        try {
            $xml = Get-Content -LiteralPath $task.BackupFile -Raw -Encoding Unicode -ErrorAction Stop
            Register-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Xml $xml -Force -ErrorAction Stop | Out-Null
            if ($task.WasEnabled) { Enable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null }
            $verifiedTasks = @(Get-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop)
            if ($verifiedTasks.Count -ne 1) {
                throw "Scheduled task verification expected one registration, found $($verifiedTasks.Count)."
            }
            $verifiedSettings = $verifiedTasks[0].PSObject.Properties['Settings']
            $verifiedEnabledProperty = if ($verifiedSettings -and $verifiedSettings.Value) { $verifiedSettings.Value.PSObject.Properties['Enabled'] } else { $null }
            if (-not $verifiedEnabledProperty) { throw 'Scheduled task enabled state could not be verified after restoration.' }
            if ([bool]$verifiedEnabledProperty.Value -ne [bool]$task.WasEnabled) {
                throw "Scheduled task enabled-state verification failed for $($task.TaskPath)$($task.TaskName)."
            }
            Write-Log "Restored and verified scheduled task: $($task.TaskPath)$($task.TaskName) (Enabled=$($task.WasEnabled))" 'OK'
        } catch {
            $message = "Could not restore task '$($task.TaskPath)$($task.TaskName)': $($_.Exception.Message)"
            $restoreErrors.Add($message)
            Write-Log $message 'ERROR'
        }
    }

    # Restore the original startup preferences even if an independent service/task restore
    # failed. This avoids leaving Edge Startup Boost, background mode, or auto-launch disabled
    # after its browser files have already been restored and SHA-256 verified.
    if ($manifest.PSObject.Properties['StartupState'] -and $manifest.StartupState) {
        if (-not (Restore-EdgeStartupMechanisms -State $manifest.StartupState)) {
            $restoreErrors.Add('One or more original startup settings could not be restored.')
        }
    } else {
        $restoreErrors.Add('The backup manifest has no original StartupState; original auto-launch preferences could not be restored.')
        Write-Log 'StartupState is missing from the backup manifest; unable to restore original auto-launch preferences.' 'ERROR'
    }

    try {
        Set-ObjectPropertyValue -Object $manifest -Name 'RestoreAttemptedAt' -Value ((Get-Date).ToString('o'))
        Set-ObjectPropertyValue -Object $manifest -Name 'RestoreStatus' -Value $(if ($restoreErrors.Count -eq 0) { 'Complete' } else { 'Incomplete' })
        if ($restoreErrors.Count -eq 0) { $manifest.RemovalState = 'Restored' }
        Set-ObjectPropertyValue -Object $manifest -Name 'RestoreErrors' -Value @($restoreErrors.ToArray())
        $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $backupDir 'manifest.json') -Encoding UTF8 -ErrorAction Stop
    } catch {
        $persistMessage = "Could not persist restoration status to manifest: $($_.Exception.Message)"
        $restoreErrors.Add($persistMessage)
        Write-Log $persistMessage 'ERROR'
    }

    if ($restoreErrors.Count -eq 0) {
        Write-Log 'Restore operation completed without detected errors. Review this log and verify Edge/WebView2 manually.' 'OK'
    } else {
        Write-Log "Restore operation completed with $($restoreErrors.Count) error(s). Review the service/task/startup errors above; the backup was retained for another restore attempt." 'ERROR'
    }
    $restoreSucceeded = ($restoreErrors.Count -eq 0)
    if ($AutomaticRollback) { return [bool]$restoreSucceeded }
    Read-Host (Get-UiText 'PressEnter') | Out-Null
}

function Remove-Backups {
    param([switch]$AfterRemoval)

    try {
        $dirs = @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction Stop)
    } catch {
        Write-Log "Could not enumerate backup directories; nothing was deleted: $($_.Exception.Message)" 'ERROR'
        Write-Host (Get-UiText 'BackupListingFailed') -ForegroundColor Red
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }
    if ($dirs.Count -eq 0) {
        Write-Log 'No backup directories found.'
        Write-Host (Get-UiText 'NoBackups')
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }

    if ($AfterRemoval) {
        Write-Host (Get-UiText 'PostRemovalBackupTitle') -ForegroundColor Yellow
    } else {
        Write-Host (Get-UiText 'DeleteBackupsTitle') -ForegroundColor Yellow
    }
    $dirs | ForEach-Object { Write-Host ('  ' + $_.FullName) }
    Write-Host (Get-UiText 'DeleteBackupsWarning') -ForegroundColor Red
    if ($AfterRemoval) {
        $confirm = Read-Host (Get-UiText 'PostRemovalConfirmDelete')
    } else {
        $confirm = Read-Host (Get-UiText 'ConfirmDelete')
    }
    if (-not [string]::Equals(([string]$confirm).Trim(), 'Y', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log 'Backup deletion cancelled; backups retained.' 'WARN'
        Write-Host (Get-UiText 'DeleteCancelled') -ForegroundColor Yellow
        Read-Host (Get-UiText 'PressEnter') | Out-Null
        return
    }

    $deleteErrors = 0
    foreach ($dir in $dirs) {
        try {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
            Write-Log "Deleted backup: $($dir.FullName)" 'OK'
        } catch {
            $deleteErrors++
            Write-Log "Could not delete backup '$($dir.FullName)': $($_.Exception.Message)" 'ERROR'
        }
    }
    if ($deleteErrors -eq 0) {
        Remove-Item -LiteralPath (Join-Path $script:BackupRoot 'latest-backup.txt') -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log "$deleteErrors backup director(y/ies) could not be deleted; latest-backup pointer was preserved." 'WARN'
    }
    Read-Host (Get-UiText 'PressEnter') | Out-Null
}

$script:Language = 'en'
function Get-UiText {
    param([Parameter(Mandatory=$true)][string]$Key)
    $messages = @{
        LanguagePrompt = @{ Zh='请选择界面语言 / Select interface language'; En='Select interface language / 请选择界面语言' }
        LanguageChinese = @{ Zh='1. 简体中文'; En='1. 简体中文 (Simplified Chinese)' }
        LanguageEnglish = @{ Zh='2. English'; En='2. English' }
        LanguageInvalid = @{ Zh='无效选择，默认使用 English。'; En='Invalid selection; defaulting to English. / 选择无效，默认使用 English。' }
        LanguageSelectedZh = @{ Zh='已选择简体中文。'; En='Simplified Chinese selected.' }
        LanguageSelectedEn = @{ Zh='已选择 English。'; En='English selected.' }
        ToolTitle = @{ Zh='WenZoo Edge 浏览器移除工具'; En='WenZoo Edge Removal Tool' }
        ToolSubtitle = @{ Zh='Microsoft Edge 移除与恢复'; En='Microsoft Edge Removal and Restore' }
        WebViewProtect = @{ Zh='WebView2 运行时保护：已启用'; En='WebView2 Runtime Protection: Enabled' }
        MenuRemove = @{ Zh='1. 彻底移除 Edge（尽可能清理残留）'; En='1. Completely Remove Edge (Best-Effort Deep Cleanup)' }
        MenuRestore = @{ Zh='2. 恢复移除前状态'; En='2. Restore Pre-Removal State' }
        MenuDeleteBackup = @{ Zh='3. 删除备份'; En='3. Delete Backup' }
        MenuExit = @{ Zh='4. 退出'; En='4. Exit' }
        SelectOption = @{ Zh='请选择操作'; En='Select an option' }
        InvalidOption = @{ Zh='选项无效，请重试。'; En='Invalid selection. Please try again.' }
        Warning1 = @{ Zh='警告：确认后，工具会先临时关闭 Edge 启动增强、后台运行和自动启动，再自动关闭传统 Edge（未保存的页面/输入内容可能丢失），然后创建并校验备份。若准备或校验失败，工具会尝试恢复原设置并清理本次不完整备份。'; En='WARNING: After confirmation, the tool temporarily disables Edge Startup Boost, background mode, and auto-launch before closing traditional Edge (unsaved pages or input may be lost), then creates and validates a backup. If preparation or validation fails, it attempts to restore the original settings and remove the incomplete backup created during this run.' }
        Warning2 = @{ Zh='WebView2 运行时目录和产品登记会受到保护；禁用或移除 Edge Update 可能同时停止 WebView2 自动更新。'; En='WebView2 Runtime files and product registration are protected; disabling/removing Edge Update may also stop WebView2 automatic updates.' }
        EdgeRunning = @{ Zh='工具无法自动停止所有传统 Edge 进程，因此已中止；未创建备份或清理。请查看日志。'; En='The tool could not automatically stop all traditional Edge processes, so it aborted before backup/cleanup. Review the log.' }
        Warning3 = @{ Zh='工具会先保存启动设置的原始状态，再禁用启动增强/后台模式和 Edge 自动启动项，随后自动关闭传统 Edge。WebView2 不会被主动结束，但移除 Edge Update 可能影响 WebView2 自动更新。备份校验通过后会直接执行移除，不会二次确认。执行中如遇到可继续处理的异常，工具会显示影响等级并询问是否继续；备份完整性、进程身份不明等安全阻断问题仍会直接中止。请先阅读 README 中的风险说明。'; En='The tool snapshots startup settings first, then disables Startup Boost/background mode and the Edge auto-launch entry before closing traditional Edge. WebView2 itself is not targeted, but removing Edge Update may affect WebView2 automatic updates. Destructive removal starts automatically after mandatory backup validation, without a second confirmation. Continueable exceptions are shown with impact levels and require explicit Y/N consent; backup-integrity, ambiguous process identity, failed Edge Update quiescence, and inventory failures remain hard blockers. Read the README risk notice before proceeding.' }
        ConfirmInitialRemove = @{ Zh='输入 Y 继续，输入 N 或其他内容取消。备份验证全部通过后将直接开始移除，不再二次确认：'; En='Enter Y to proceed, or N/anything else to cancel. Removal starts automatically after mandatory backup validation; there is no second confirmation:' }
        BackupComplete = @{ Zh='备份已创建，文件路径、数量及大小检查通过。'; En='Backup created; file/path/size integrity checks passed.' }
        BackupLocation = @{ Zh='备份位置 / Backup location:'; En='Backup location / 备份位置:' }
        BackupAutoContinue = @{ Zh='备份校验成功，立即开始移除；不会再次要求确认。'; En='Backup validation passed. Removal begins immediately; no second confirmation is requested.' }
        BackupSafetyGateNotice = @{ Zh='备份校验通过。当前测试版会在安全锁处停止，不执行实际移除；不会再次要求确认。'; En='Backup validation passed. This staged build stops at the safety gate and will not remove Edge; no second confirmation is requested.' }
        RemovalCancelledBackupKept = @{ Zh='已取消移除，备份已保留；系统未执行 Edge 清理。'; En='Removal cancelled. The backup is retained; no Edge cleanup was performed.' }
        RemovalBlockedStage = @{ Zh='安全锁已生效：当前测试版本不会执行删除。备份已保留供测试，系统未被清理。'; En='Safety gate active: this staged build will not execute deletion. The validated backup is retained for testing; the system was not cleaned.' }
        RemovalResidualsBackupKept = @{ Zh='移除流程发现残留或异常。为保留恢复能力，备份未自动删除；请查看日志和移除报告。'; En='Residuals or exceptions were found. The backup was retained for recovery; review the log and removal report.' }
        StageBanner = @{ Zh='测试阶段：仅验证备份；实际删除功能已锁定'; En='STAGING BUILD: Backup validation only; destructive removal is disabled' }
        StageBannerEnabled = @{ Zh='正式版本 v0.5.1：实际移除功能已启用'; En='RELEASE v0.5.1: destructive removal is enabled' }
        PressEnter = @{ Zh='按 Enter 返回菜单'; En='Press Enter to return to the menu' }
        NoBackup = @{ Zh='未找到有效备份，无法恢复。'; En='No valid backup found. Nothing to restore.' }
        SelectedBackup = @{ Zh='选中的备份'; En='Backup selected' }
        RestoreWarning = @{ Zh='恢复可能覆盖当前文件，并恢复备份中记录的 Edge Update 服务和计划任务状态。'; En='Restoration may overwrite current files and restore the recorded Edge Update service/task state.' }
        ConfirmRestore = @{ Zh='输入 Y 继续恢复，输入 N 或其他内容取消：'; En='Enter Y to restore, or N/anything else to cancel:' }
        RestoreCancelled = @{ Zh='用户取消了恢复。'; En='Restore cancelled by user.' }
        NoBackups = @{ Zh='没有找到备份目录。'; En='No backup directories found.' }
        BackupListingFailed = @{ Zh='无法读取备份目录，未删除任何备份。请检查权限和日志。'; En='Could not read the backup directory; no backups were deleted. Check permissions and the log.' }
        NoRestorableBackup = @{ Zh='未找到可恢复的备份。取消清理的备份不会自动恢复，以免覆盖仍在使用的浏览器数据。'; En='No restore-eligible backup found. Backups from a cancelled removal are not restored, to avoid overwriting live browser data.' }
        DeleteBackupsTitle = @{ Zh='以下备份目录将被永久删除：'; En='The following backup directories will be permanently deleted:' }
        PostRemovalBackupTitle = @{ Zh='清理流程已结束。可在此处直接决定是否清理备份：'; En='The cleanup workflow has finished. You can decide whether to delete backups now:' }
        DeleteBackupsWarning = @{ Zh='此操作不可撤销。确认不再需要恢复后再删除备份。'; En='This cannot be undone. Delete backups only when restoration is no longer needed.' }
        ConfirmDelete = @{ Zh='输入 Y 删除上方列出的全部备份，输入 N 或其他内容保留：'; En='Enter Y to delete ALL backup folders listed above, or N/anything else to keep them:' }
        PostRemovalConfirmDelete = @{ Zh='如要立即永久删除上方列出的全部备份（包括本次备份），输入 Y；输入 N 或其他内容则保留备份：'; En="To permanently delete ALL listed backups (including this run's backup) now, enter Y; enter N or anything else to keep them:" }
        DeleteCancelled = @{ Zh='已取消删除备份，备份仍然保留。'; En='Backup deletion cancelled; backups have been retained.' }
        RuntimeExceptionHeading = @{ Zh='检测到可继续处理的异常：'; En='Non-blocking exceptions were detected:' }
        FinalResidualHeading = @{ Zh='最终核验发现以下残留：'; En='Final verification found the following residual items:' }
        FinalResidualSafetyNote = @{ Zh='主浏览器可执行文件已单独核验不存在。以下是非核心残留；接受后流程将标记为“已完成但存在残留”，并保留备份。'; En='The main browser executable was separately verified absent. These are non-core residuals; accepting them marks the result as completed with residuals and keeps the backup.' }
        AcceptResidualsPrompt = @{ Zh='如接受尽力清理结果并保留备份，请输入 Y；输入 N 或其他内容将标记为部分完成：'; En='Enter Y to accept the best-effort result and keep the backup; N or anything else marks the removal Partial:' }
        SeverityLow = @{ Zh='低影响'; En='LOW IMPACT' }
        SeverityModerate = @{ Zh='中等影响'; En='MODERATE IMPACT' }
        SeverityHigh = @{ Zh='较高影响'; En='HIGH IMPACT' }
        ImpactLabel = @{ Zh='可能影响'; En='Potential impact' }
        RuntimeExceptionSafetyNote = @{ Zh='这些异常不会自动视为成功；请阅读影响说明。选择 N 将停止后续清理，并尝试从本次备份恢复文件、注册表、服务、计划任务和启动设置；只有完整恢复及校验成功后，才会删除本次临时备份。若恢复失败，备份会保留供再次恢复。'; En='These exceptions are not treated as success. Read the impact notes. Choosing N stops further cleanup and attempts to restore files, registry, services, scheduled tasks, and startup settings from this run''s backup. The temporary backup is deleted only after full restoration and verification succeed; otherwise it is retained for another recovery attempt.' }
        ContinueAfterException = @{ Zh='如接受上述风险并继续后续清理，请输入 Y；输入 N 或其他内容将停止后续清理并保留备份：'; En='Enter Y to accept these risks and continue cleanup; N or anything else stops further cleanup and retains the backup:' }
        ExitLog = @{ Zh='用户已退出。'; En='Exited by user.' }
    }
    if (-not $messages.ContainsKey($Key)) { return $Key }
    if ($script:Language -eq 'zh') { return $messages[$Key].Zh }
    return $messages[$Key].En
}

Clear-Host
Write-Host '========================================' -ForegroundColor Cyan
Write-Host (Get-UiText 'LanguagePrompt') -ForegroundColor Cyan
Write-Host (Get-UiText 'LanguageChinese')
Write-Host (Get-UiText 'LanguageEnglish')
$langChoice = Read-Host '1 / 2'
switch ($langChoice) {
    '1' { $script:Language = 'zh'; Write-Log 'User selected UI language: Simplified Chinese.' }
    '2' { $script:Language = 'en'; Write-Log 'User selected UI language: English.' }
    default { $script:Language = 'en'; Write-Host (Get-UiText 'LanguageInvalid') -ForegroundColor Yellow }
}

$exitRequested = $false
while (-not $exitRequested) {
    Clear-Host
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host (' ' + (Get-UiText 'ToolTitle')) -ForegroundColor Cyan
    Write-Host (' ' + (Get-UiText 'ToolSubtitle')) -ForegroundColor Cyan
    Write-Host (' ' + (Get-UiText 'WebViewProtect')) -ForegroundColor Green
    $stageBannerKey = if ($script:EnableRemovalExecution) { 'StageBannerEnabled' } else { 'StageBanner' }
    Write-Host (' ' + (Get-UiText $stageBannerKey)) -ForegroundColor Yellow
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host (Get-UiText 'MenuRemove')
    Write-Host (Get-UiText 'MenuRestore')
    Write-Host (Get-UiText 'MenuDeleteBackup')
    Write-Host (Get-UiText 'MenuExit')
    Write-Host ''
    $choice = Read-Host (Get-UiText 'SelectOption')
    switch ($choice) {
        '1' {
            Write-Host ''
            Write-Host (Get-UiText 'Warning1') -ForegroundColor Red
            Write-Host (Get-UiText 'Warning2') -ForegroundColor Yellow
            Write-Host (Get-UiText 'Warning3') -ForegroundColor Yellow
            $confirm = Read-Host (Get-UiText 'ConfirmInitialRemove')
            if ([string]::Equals(([string]$confirm).Trim(), 'Y', [System.StringComparison]::OrdinalIgnoreCase)) {
                try { Remove-Edge } catch { Write-Log "Removal aborted: $($_.Exception.Message)" 'ERROR'; Read-Host (Get-UiText 'PressEnter') | Out-Null }
            } else { Write-Log 'Removal cancelled by user.' 'WARN'; Start-Sleep -Seconds 1 }
        }
        '2' { Restore-PreRemovalState }
        '3' { Remove-Backups }
        '4' { Write-Log 'Exited by user.'; Write-Host (Get-UiText 'ExitLog') -ForegroundColor Gray; [Environment]::Exit(0) }
        default { Write-Host (Get-UiText 'InvalidOption') -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
}

