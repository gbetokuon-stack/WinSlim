#Requires -Version 5.1
<#
.SYNOPSIS
    WinSlim - a transparent Windows 10/11 optimizer for low-end PCs.

.DESCRIPTION
    Menu-driven cleanup and tuning tool inspired by WinUtil, but focused on
    weak hardware. Every registry value, service, scheduled task and power
    setting changed by the tool is recorded first, so it can be reverted.

    Deliberately NOT included: disabling Defender, Firewall or Windows Update,
    deleting the pagefile/prefetch, or "magic" RAM cleaners.

.PARAMETER Preset
    Menu (default), Safe, Balanced, Aggressive or Ultra.
    Ultra is the maximum-savings mode for 2-4 GB RAM / old CPU machines.

.PARAMETER Yes
    Answer yes to confirmations (unattended runs). Use only if you understand
    exactly what the chosen preset does.

.PARAMETER DryRun
    Show what would change without writing anything.

.PARAMETER NoRestorePoint
    Do not create a System Restore point before the first change.

.PARAMETER NoElevate
    Do not auto-relaunch as administrator (read-only mode for browsing).

.PARAMETER Report
    Print a system report and exit.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Preset Balanced

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Preset Aggressive -DryRun -NoElevate

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Preset Ultra
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Safe', 'Balanced', 'Aggressive', 'Ultra')]
    [string]$Preset = 'Menu',

    [switch]$Yes,
    [switch]$DryRun,
    [switch]$NoRestorePoint,
    [switch]$NoElevate,
    [switch]$Report
)

$script:Version      = '1.1.0'
$script:ScriptPath   = $PSCommandPath
$script:DryRun       = [bool]$DryRun
$script:AutoYes      = [bool]$Yes
$script:SkipRestore  = [bool]$NoRestorePoint
$script:IsAdmin      = ([Security.Principal.WindowsPrincipal](
                            [Security.Principal.WindowsIdentity]::GetCurrent()
                        )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------------- elevation --
if (-not $script:IsAdmin -and -not $script:DryRun -and -not $Report -and -not $NoElevate) {
    if (-not $script:ScriptPath) {
        Write-Host ''
        Write-Host '  [!] WinSlim cannot self-elevate when piped into memory.' -ForegroundColor Yellow
        Write-Host '      Save it first:  irm <url> -OutFile .\WinSlim.ps1' -ForegroundColor Yellow
        exit 1
    }

    Write-Host ''
    Write-Host '  Requesting administrator privileges...' -ForegroundColor Yellow
    $exePath = Join-Path $PSHOME 'powershell.exe'
    if ($PSVersionTable.PSEdition -eq 'Core') { $exePath = Join-Path $PSHOME 'pwsh.exe' }
    if (-not (Test-Path -LiteralPath $exePath)) { $exePath = (Get-Process -Id $PID).Path }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:ScriptPath))
    if ($Preset -ne 'Menu') { $argList += @('-Preset', $Preset) }
    if ($Yes)              { $argList += '-Yes' }
    if ($NoRestorePoint)   { $argList += '-NoRestorePoint' }

    try {
        Start-Process -FilePath $exePath -Verb RunAs -WorkingDirectory (Split-Path -Parent $script:ScriptPath) `
            -ArgumentList ($argList -join ' ') -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host '  Elevation was cancelled or failed.' -ForegroundColor Red
        exit 1
    }
    exit 0
}

# --------------------------------------------------------------- log helpers --
function Initialize-Session {
    $script:AppRoot    = Join-Path $env:ProgramData 'WinSlim'
    $script:BackupRoot = Join-Path $script:AppRoot 'Backups'
    $script:LogRoot    = Join-Path $env:LOCALAPPDATA 'WinSlim\Logs'
    $script:Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile    = Join-Path $script:LogRoot ('winslim-{0}.log' -f $script:Stamp)

    try {
        New-Item -ItemType Directory -Force -Path $script:LogRoot -ErrorAction Stop | Out-Null
    }
    catch {
        $script:LogFile = $null
    }

    $script:RegTouched   = 0
    $script:ServiceTouched = 0
    $script:TaskTouched  = 0
    $script:AppRemoved   = 0
    $script:ActionTouched = 0
    $script:SafetyPointCreated = $false
    $script:BackupSaved  = $false

    New-BackupState

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Write-Log ('WinSlim {0} started (admin={1}, dryRun={2}).' -f $script:Version, $script:IsAdmin, $script:DryRun) 'INFO'
    if ($os) {
        Write-Log ('Host: {0} / {1} build {2}' -f $os.Caption, $os.Version, $os.BuildNumber) 'INFO'
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )

    if ($script:LogFile) {
        try {
            $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }

    $tag = '[i]'
    $color = 'Gray'
    switch ($Level) {
        'OK'    { $tag = '[+]'; $color = 'Green' }
        'WARN'  { $tag = '[!]'; $color = 'Yellow' }
        'ERROR' { $tag = '[x]'; $color = 'Red' }
        'STEP'  { $tag = '[>]'; $color = 'Cyan' }
    }
    Write-Host ('  {0} {1}' -f $tag, $Message) -ForegroundColor $color
}

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host ''
    Write-Host ('  --- {0} ' -f $Title).PadRight(62, '-') -ForegroundColor Cyan
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value ('--- {0} ---' -f $Title) -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function Confirm-Continue {
    param(
        [string]$Question = 'Continue?',
        [switch]$DefaultYes
    )
    if ($script:AutoYes) { return $true }
    $suffix = '[y/N]'
    if ($DefaultYes) { $suffix = '[Y/n]' }
    $answer = Read-Host ('  {0} {1}' -f $Question, $suffix)
    if ([string]::IsNullOrWhiteSpace($answer)) { return [bool]$DefaultYes }
    return ($answer -match '^(y|yes)$')
}

function Wait-ForKey {
    Write-Host ''
    Write-Host '  Press Enter to continue...' -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

function Assert-Admin {
    if ($script:IsAdmin -or $script:DryRun) { return $true }
    Write-Log 'Administrator rights are required for this action.' 'ERROR'
    Write-Host '  Relaunch WinSlim as administrator (do not use -NoElevate).' -ForegroundColor Yellow
    return $false
}

# ------------------------------------------------------------- backup engine --
function New-BackupState {
    $script:Stamp      = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $script:BackupDir  = Join-Path $script:BackupRoot $script:Stamp
    $script:BackupSaved = $false
    $script:Backup = [pscustomobject]@{
        Tool     = 'WinSlim'
        Version  = $script:Version
        Created  = (Get-Date).ToString('o')
        Computer = $env:COMPUTERNAME
        User     = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        Registry = @()
        Services = @()
        Tasks    = @()
        Actions  = @()
    }
    $script:RegIndex     = @{}
    $script:ServiceIndex = @{}
    $script:TaskIndex    = @{}
    $script:ActionIndex  = @{}
}

function Add-BackupRecord {
    param(
        [ValidateSet('Registry', 'Service', 'Task')][string]$Kind,
        [hashtable]$Data
    )
    if ($script:DryRun) { return }

    switch ($Kind) {
        'Registry' {
            $id = '{0}|{1}' -f $Data.Path, $Data.Name
            if ($script:RegIndex.ContainsKey($id)) { return }
            $script:RegIndex[$id] = $true
            $script:Backup.Registry += [pscustomobject]$Data
        }
        'Service' {
            if ($script:ServiceIndex.ContainsKey($Data.Name)) { return }
            $script:ServiceIndex[$Data.Name] = $true
            $script:Backup.Services += [pscustomobject]$Data
        }
        'Task' {
            $id = '{0}{1}' -f $Data.TaskPath, $Data.TaskName
            if ($script:TaskIndex.ContainsKey($id)) { return }
            $script:TaskIndex[$id] = $true
            $script:Backup.Tasks += [pscustomobject]$Data
        }
    }
}

function Add-BackupAction {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [hashtable]$Data = @{},
        # Optional discriminator so several actions of the same type can be
        # recorded (for example one per disabled startup entry).
        [string]$Key
    )
    if ($script:DryRun) { return }
    $id = $Type
    if (-not [string]::IsNullOrWhiteSpace($Key)) { $id = '{0}|{1}' -f $Type, $Key }
    if ($script:ActionIndex.ContainsKey($id)) { return }
    $script:ActionIndex[$id] = $true
    $script:Backup.Actions += [pscustomobject]@{ Type = $Type; Data = $Data }
    $script:ActionTouched++
}

function Save-BackupState {
    if ($script:DryRun) { return }
    if (-not $script:IsAdmin) { return }

    $count = @($script:Backup.Registry).Count + @($script:Backup.Services).Count +
             @($script:Backup.Tasks).Count + @($script:Backup.Actions).Count
    if ($count -eq 0) { return }

    try {
        New-Item -ItemType Directory -Force -Path $script:BackupDir -ErrorAction Stop | Out-Null
        $script:Backup | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $script:BackupDir 'manifest.json') -Encoding UTF8 -ErrorAction Stop
        $script:BackupSaved = $true
    }
    catch {
        $script:BackupSaved = $false
        Write-Log ('Could not save backup manifest: {0}' -f $_.Exception.Message) 'ERROR'
    }
}

# ------------------------------------------------------- registry / services --
function Set-RegValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateSet('DWord', 'String', 'QWord', 'MultiString', 'Binary', 'ExpandString')]
        [string]$Type = 'DWord'
    )

    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    $keyExisted = ($null -ne $key)
    $existed = $false
    $oldValue = $null
    $oldType = 'String'

    if ($keyExisted -and (@($key.GetValueNames()) -contains $Name)) {
        $existed = $true
        try {
            $oldValue = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $oldType = $key.GetValueKind($Name).ToString()
        }
        catch {
            $oldType = 'String'
        }
    }

    # Skip values that are already correct; avoid pointless backup noise.
    if ($existed -and $oldType -eq $Type -and
        $oldValue -isnot [System.Array] -and $Value -isnot [System.Array]) {
        if ([string]$oldValue -ceq [string]$Value) { return }
    }

    if (-not $script:DryRun) {
        Add-BackupRecord -Kind 'Registry' -Data @{
            Path       = $Path
            Name       = $Name
            Existed    = $existed
            KeyExisted = $keyExisted
            Value      = $oldValue
            ValueType  = $oldType
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        try {
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        }
    }

    $script:RegTouched++
}

function Set-RegistryList {
    param([object[]]$Items)
    $ok = 0
    foreach ($item in $Items) {
        try {
            Set-RegValue -Path $item.P -Name $item.N -Value $item.V -Type $item.T
            $ok++
        }
        catch {
            Write-Log ('Registry: could not set {0} -> {1}: {2}' -f $item.P, $item.N, $_.Exception.Message) 'WARN'
        }
    }
    return $ok
}

function Set-ServiceSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Automatic', 'Manual', 'Disabled')][string]$StartupType
    )

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log ('Service not present: {0} (skipped)' -f $Name) 'INFO'
        return $false
    }

    $oldStart = 'Manual'
    try { $oldStart = $svc.StartType.ToString() } catch { }

    if ($script:DryRun) {
        Write-Log ('[dry] service {0}: {1} -> {2}' -f $Name, $oldStart, $StartupType) 'INFO'
        return $true
    }

    Add-BackupRecord -Kind 'Service' -Data @{
        Name      = $Name
        StartType = $oldStart
        Status    = $svc.Status.ToString()
    }

    try {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        if ($StartupType -eq 'Disabled' -and $svc.Status -eq 'Running') {
            Stop-Service -Name $Name -Force -NoWait -ErrorAction SilentlyContinue
        }
        $script:ServiceTouched++
        Write-Log ('Service {0} -> {1}' -f $Name, $StartupType) 'OK'
        return $true
    }
    catch {
        Write-Log ('Service {0} could not be changed: {1}' -f $Name, $_.Exception.Message) 'WARN'
        return $false
    }
}

function Disable-TaskTweak {
    param(
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [Parameter(Mandatory = $true)][string]$TaskName
    )

    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $false }

    if ($script:DryRun) {
        Write-Log ('[dry] task {0}{1} -> Disabled' -f $TaskPath, $TaskName) 'INFO'
        return $true
    }

    Add-BackupRecord -Kind 'Task' -Data @{
        TaskPath = $TaskPath
        TaskName = $TaskName
        State    = $task.State.ToString()
    }

    try {
        if ($task.State -ne 'Disabled') {
            Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
            $script:TaskTouched++
            Write-Log ('Task disabled: {0}{1}' -f $TaskPath, $TaskName) 'OK'
        }
        return $true
    }
    catch {
        Write-Log ('Task {0}{1} could not be disabled: {2}' -f $TaskPath, $TaskName, $_.Exception.Message) 'WARN'
        return $false
    }
}

# ------------------------------------------------------------- safety net etc. --
function New-SafetyPoint {
    param([string]$Label = 'WinSlim')

    if ($script:DryRun) {
        Write-Log '[dry] would create a System Restore point.' 'INFO'
        return
    }

    Write-Log 'Creating a System Restore point (this can take a minute)...' 'INFO'
    try {
        Enable-ComputerRestore -Drive ('{0}\' -f $env:SystemDrive) -ErrorAction Stop
    }
    catch {
        Write-Log ('System Restore could not be enabled: {0}' -f $_.Exception.Message) 'WARN'
    }

    try {
        Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
            -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord
    }
    catch {
        Write-Log ('Could not adjust restore-point frequency: {0}' -f $_.Exception.Message) 'WARN'
    }

    try {
        Checkpoint-Computer -Description ('WinSlim - {0}' -f $Label) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log 'System Restore point created.' 'OK'
    }
    catch {
        Write-Log ('Restore point was not created (continuing): {0}' -f $_.Exception.Message) 'WARN'
    }
}

function Ensure-SafetyPoint {
    if ($script:DryRun -or $script:SkipRestore -or $script:SafetyPointCreated) { return }
    $script:SafetyPointCreated = $true
    New-SafetyPoint -Label 'automatic'
}

function Get-TotalChanges {
    return ($script:RegTouched + $script:ServiceTouched + $script:TaskTouched +
            $script:AppRemoved + $script:ActionTouched)
}

function Show-SessionSummary {
    $total = Get-TotalChanges
    Write-Host ''
    if ($script:DryRun) {
        Write-Host '  DRY RUN: no changes were written.' -ForegroundColor Yellow
    }
    elseif ($total -eq 0) {
        Write-Host '  No changes in this session.' -ForegroundColor DarkGray
    }
    else {
        Write-Host ('  Session: {0} registry value(s), {1} service(s), {2} task(s), {3} app(s), {4} action(s).' -f `
            $script:RegTouched, $script:ServiceTouched, $script:TaskTouched, $script:AppRemoved, $script:ActionTouched) -ForegroundColor Green
        if ($script:BackupSaved) {
            Write-Host ('  Backup: {0}' -f $script:BackupDir) -ForegroundColor DarkGray
        }
        else {
            Write-Host '  WARNING: backup manifest was not saved. Use System Restore if you need to undo.' -ForegroundColor Red
        }
        Write-Host '  Sign out or restart to apply everything.' -ForegroundColor Yellow
    }
    if ($script:LogFile) {
        Write-Host ('  Log: {0}' -f $script:LogFile) -ForegroundColor DarkGray
    }
}

function Reset-SessionBackup {
    New-BackupState
    $script:RegTouched = 0
    $script:ServiceTouched = 0
    $script:TaskTouched = 0
    $script:AppRemoved = 0
    $script:ActionTouched = 0
    $script:SafetyPointCreated = $false
}

# ------------------------------------------------------- privacy / telemetry --
function Invoke-PrivacyTweaks {
    if (-not (Assert-Admin)) { return }
    Ensure-SafetyPoint
    Write-Section 'Privacy and telemetry'

    $items = @(
        # Advertising ID
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N = 'Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; N = 'DisabledByGroupPolicy'; V = 1; T = 'DWord' }

        # Diagnostic data
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; N = 'AllowTelemetry'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'LimitDiagnosticLogCollection'; V = 1; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'LimitDumpCollection'; V = 1; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'DisableOneSettingsDownloads'; V = 1; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'DoNotShowFeedbackNotifications'; V = 1; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; N = 'TailoredExperiencesWithDiagnosticDataEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Siuf\Rules'; N = 'NumberOfSIUFInPeriod'; V = 0; T = 'DWord' }

        # Activity history
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'EnableActivityFeed'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'PublishUserActivities'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'UploadUserActivities'; V = 0; T = 'DWord' }

        # Input / speech personalization
        @{ P = 'HKCU:\Software\Microsoft\InputPersonalization'; N = 'RestrictImplicitTextCollection'; V = 1; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\InputPersonalization'; N = 'RestrictImplicitInkCollection'; V = 1; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore'; N = 'HarvestContacts'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Input\TIPC'; N = 'Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; N = 'HasAccepted'; V = 0; T = 'DWord' }

        # Error reporting
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; N = 'Disabled'; V = 1; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; N = 'DontSendAdditionalData'; V = 1; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\Windows Error Reporting'; N = 'Disabled'; V = 1; T = 'DWord' }

        # Consumer features, ads, suggestions
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; N = 'DisableWindowsConsumerFeatures'; V = 1; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; N = 'DisableSoftLanding'; V = 1; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'ContentDeliveryAllowed'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'OemPreInstalledAppsEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'PreInstalledAppsEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'PreInstalledAppsEverEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SilentInstalledAppsEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SoftLandingEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SystemPaneSuggestionsEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'RotatingLockScreenOverlayEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-310093Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338387Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338388Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338389Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338393Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-353694Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-353696Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; N = 'ScoobeSystemSettingEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_IrisRecommendations'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_AccountNotifications'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ShowSyncProviderNotifications'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'TaskbarDa'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'TaskbarMn'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ShowCopilotButton'; V = 0; T = 'DWord' }

        # Search: web results, Cortana, cloud search, highlights
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'AllowCortana'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'AllowSearchToUseLocation'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'DisableWebSearch'; V = 1; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'ConnectedSearchUseWeb'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'EnableDynamicContentInWSB'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; N = 'DisableSearchBoxSuggestions'; V = 1; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; N = 'BingSearchEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; N = 'CortanaConsent'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; N = 'IsDynamicSearchBoxEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; N = 'IsMSACloudSearchEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; N = 'IsAADCloudSearchEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; N = 'IsDeviceSearchHistoryEnabled'; V = 0; T = 'DWord' }

        # Copilot / Recall (Windows 11)
        @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot'; V = 1; T = 'DWord' }
        @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; V = 1; T = 'DWord' }
    )

    $n = Set-RegistryList -Items $items
    Write-Log ('Privacy: {0} registry setting(s) processed.' -f $n) 'OK'
}

# ------------------------------------------------- services / scheduled tasks --
function Invoke-ServicesAndTasks {
    if (-not (Assert-Admin)) { return }
    Ensure-SafetyPoint
    Write-Section 'Background services and telemetry tasks'

    $services = @(
        @{ N = 'DiagTrack';        S = 'Disabled' }
        @{ N = 'dmwappushservice'; S = 'Disabled' }
        @{ N = 'MapsBroker';       S = 'Disabled' }
        @{ N = 'RetailDemo';       S = 'Disabled' }
        @{ N = 'WMPNetworkSvc';    S = 'Disabled' }
        @{ N = 'RemoteRegistry';   S = 'Disabled' }
        @{ N = 'Fax';              S = 'Disabled' }
        @{ N = 'WerSvc';           S = 'Manual'   }
    )
    foreach ($s in $services) {
        [void](Set-ServiceSetting -Name $s.N -StartupType $s.S)
    }

    $tasks = @(
        @{ P = '\Microsoft\Windows\Application Experience\'; N = 'Microsoft Compatibility Appraiser' }
        @{ P = '\Microsoft\Windows\Application Experience\'; N = 'ProgramDataUpdater' }
        @{ P = '\Microsoft\Windows\Application Experience\'; N = 'PcaPatchDbTask' }
        @{ P = '\Microsoft\Windows\Application Experience\'; N = 'StartupAppTask' }
        @{ P = '\Microsoft\Windows\Autochk\'; N = 'Proxy' }
        @{ P = '\Microsoft\Windows\Customer Experience Improvement Program\'; N = 'Consolidator' }
        @{ P = '\Microsoft\Windows\Customer Experience Improvement Program\'; N = 'UsbCeip' }
        @{ P = '\Microsoft\Windows\DiskDiagnostic\'; N = 'Microsoft-Windows-DiskDiagnosticDataCollector' }
        @{ P = '\Microsoft\Windows\Feedback\Siuf\'; N = 'DmClient' }
        @{ P = '\Microsoft\Windows\Feedback\Siuf\'; N = 'DmClientOnScenarioDownload' }
        @{ P = '\Microsoft\Windows\Windows Error Reporting\'; N = 'QueueReporting' }
        @{ P = '\Microsoft\Windows\Maintenance\'; N = 'WinSAT' }
    )
    foreach ($t in $tasks) {
        [void](Disable-TaskTweak -TaskPath $t.P -TaskName $t.N)
    }

    Write-Log ('Services: {0} changed, tasks: {1} disabled.' -f $script:ServiceTouched, $script:TaskTouched) 'OK'
}

# ------------------------------------------------------------------ debloat --
$script:BloatPatterns = @(
    'Microsoft.BingNews'
    'Microsoft.BingWeather'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.Microsoft3DViewer'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MixedReality.Portal'
    'Microsoft.People'
    'Microsoft.SkypeApp'
    'Microsoft.Todos'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.WindowsMaps'
    'Microsoft.549981C3F5F10'
    'Microsoft.Windows.Cortana'
    'Microsoft.WindowsReadingList'
    'Microsoft.WindowsScan'
    'Microsoft.OneConnect'
    'Microsoft.MSPaint'
    'Microsoft.Print3D'
    'Microsoft.Office.Sway'
    'MicrosoftTeams'
    'Clipchamp.Clipchamp'
    '*CandyCrush*'
    '*BubbleWitch*'
    '*Facebook*'
    '*Twitter*'
    '*Instagram*'
    '*TikTok*'
    '*Netflix*'
    '*Spotify*'
    '*Disney*'
    '*LinkedIn*'
    '*King.com*'
    '*Duolingo*'
    '*AdobePhotoshopExpress*'
    '*PandoraMedia*'
    '*EclipseManager*'
)

# Extra consumer apps removed only by the Ultra preset. These are heavier
# (or more optional) than the Balanced list, so they stay opt-in.
$script:UltraBloatPatterns = @(
    'MicrosoftWindows.Client.WebExperience'  # Widgets (Windows 11)
    'Microsoft.Windows.DevHome'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.YourPhone'                    # Phone Link
    'Microsoft.windowscommunicationsapps'    # Mail and Calendar
    'Microsoft.OutlookForWindows'            # new Outlook
    'Microsoft.ZuneVideo'                    # Movies & TV
    'Microsoft.Copilot'
)

$script:AppWhitelist = @(
    'Microsoft.WindowsStore'
    'Microsoft.StorePurchaseApp'
    'Microsoft.DesktopAppInstaller'
    'Microsoft.VCLibs'
    'Microsoft.UI.Xaml'
    'Microsoft.NET'
    'Microsoft.WindowsAppRuntime'
    'Microsoft.Services.Store'
    'Microsoft.Windows.ShellExperienceHost'
    'Microsoft.Windows.StartMenuExperienceHost'
    'Microsoft.WindowsTerminal'
    'Microsoft.WindowsCalculator'
    'Microsoft.ScreenSketch'
    'Microsoft.Windows.Photos'
    'Microsoft.Paint'
    'Microsoft.WindowsNotepad'
    'Microsoft.WindowsCamera'
    'Microsoft.WindowsSoundRecorder'
    'Microsoft.SecHealthUI'
    'Microsoft.AAD.BrokerPlugin'
    'Microsoft.AccountsControl'
    'Microsoft.LockApp'
    'Microsoft.Win32WebViewHost'
    'Microsoft.Windows.CloudExperienceHost'
    'Microsoft.CredDialogHost'
    'Microsoft.ECApp'
    'MicrosoftWindows.Client'
)

function Test-AppWhitelisted {
    param([string]$Name)
    foreach ($prefix in $script:AppWhitelist) {
        if ($Name -like ('{0}*' -f $prefix)) { return $true }
    }
    return $false
}

function Get-DebloatUserApps {
    param([switch]$Ultra)
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return @() }

    $patterns = @($script:BloatPatterns)
    if ($Ultra) { $patterns += $script:UltraBloatPatterns }

    try {
        $packages = @(Get-AppxPackage -ErrorAction Stop)
    }
    catch {
        Write-Log ('Could not enumerate Store apps: {0}' -f $_.Exception.Message) 'WARN'
        return @()
    }

    $found = @()
    foreach ($pkg in $packages) {
        if (-not $pkg -or $pkg.IsFramework) { continue }
        if (Test-AppWhitelisted -Name $pkg.Name) { continue }
        foreach ($pattern in $patterns) {
            if ($pkg.Name -like $pattern -or $pkg.PackageFamilyName -like $pattern) {
                $found += $pkg
                break
            }
        }
    }
    return @($found | Sort-Object Name -Unique)
}

function Get-DebloatProvisionedApps {
    param([switch]$Ultra)
    if (-not $script:IsAdmin) { return @() }
    if (-not (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue)) { return @() }

    $patterns = @($script:BloatPatterns)
    if ($Ultra) { $patterns += $script:UltraBloatPatterns }

    try {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
    }
    catch {
        Write-Log ('Could not enumerate provisioned apps: {0}' -f $_.Exception.Message) 'WARN'
        return @()
    }

    $found = @()
    foreach ($pkg in $provisioned) {
        if (-not $pkg) { continue }
        if (Test-AppWhitelisted -Name $pkg.DisplayName) { continue }
        foreach ($pattern in $patterns) {
            if ($pkg.DisplayName -like $pattern -or $pkg.PackageName -like $pattern) {
                $found += $pkg
                break
            }
        }
    }
    return @($found | Sort-Object PackageName -Unique)
}

function Invoke-Debloat {
    param([switch]$NoPrompt, [switch]$Ultra)

    if (-not (Assert-Admin)) { return }
    Write-Section 'Debloat: consumer and junk apps'

    $userApps = @(Get-DebloatUserApps -Ultra:$Ultra)
    $provApps = @(Get-DebloatProvisionedApps -Ultra:$Ultra)

    if ($userApps.Count -eq 0 -and $provApps.Count -eq 0) {
        Write-Log 'No matching bloatware packages found.' 'OK'
        return
    }

    Write-Host ('  Found {0} app(s) for this user and {1} provisioned package(s).' -f $userApps.Count, $provApps.Count) -ForegroundColor Gray
    foreach ($app in @($userApps | Select-Object -First 12)) {
        Write-Host ('    - {0}' -f $app.Name) -ForegroundColor DarkGray
    }
    if ($userApps.Count -gt 12) {
        Write-Host ('    ... and {0} more' -f ($userApps.Count - 12)) -ForegroundColor DarkGray
    }

    if (-not $NoPrompt -and -not (Confirm-Continue 'Remove these apps? (reinstallable from the Store)')) {
        return
    }

    Ensure-SafetyPoint

    foreach ($app in $userApps) {
        if ($script:DryRun) {
            Write-Log ('[dry] remove app for current user: {0}' -f $app.Name) 'INFO'
            continue
        }
        try {
            Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
            $script:AppRemoved++
            Write-Log ('Removed app: {0}' -f $app.Name) 'OK'
        }
        catch {
            Write-Log ('Could not remove {0}: {1}' -f $app.Name, $_.Exception.Message) 'WARN'
        }
    }

    foreach ($pkg in $provApps) {
        if ($script:DryRun) {
            Write-Log ('[dry] remove provisioned package: {0}' -f $pkg.DisplayName) 'INFO'
            continue
        }
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
            $script:AppRemoved++
            Write-Log ('Removed provisioned package: {0}' -f $pkg.DisplayName) 'OK'
        }
        catch {
            Write-Log ('Could not remove provisioned {0}: {1}' -f $pkg.DisplayName, $_.Exception.Message) 'WARN'
        }
    }

    Write-Log ('Debloat done: {0} item(s) removed.' -f $script:AppRemoved) 'OK'
    Write-Host '  Note: removed Store apps can be reinstalled from the Microsoft Store.' -ForegroundColor DarkGray
}

# ------------------------------------------------------- performance / UI --
function Invoke-PerformanceTweaks {
    if (-not (Assert-Admin)) { return }
    Ensure-SafetyPoint
    Write-Section 'Performance and interface'

    $items = @(
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; N = 'VisualFXSetting'; V = 2; T = 'DWord' }
        @{ P = 'HKCU:\Control Panel\Desktop'; N = 'MenuShowDelay'; V = '0'; T = 'String' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'TaskbarAnimations'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ListviewAlphaSelect'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ListviewShadow'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; N = 'EnableTransparency'; V = 0; T = 'DWord' }

        # Background apps: fewer wake-ups and less RAM use
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; N = 'GlobalUserDisabled'; V = 1; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; N = 'LetAppsRunInBackground'; V = 2; T = 'DWord' }

        # Game DVR / background recording
        @{ P = 'HKCU:\System\GameConfigStore'; N = 'GameDVR_Enabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'AppCaptureEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'HistoricalCaptureEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; N = 'AllowGameDVR'; V = 0; T = 'DWord' }
    )

    $n = Set-RegistryList -Items $items
    Write-Log ('Performance: {0} registry setting(s) processed.' -f $n) 'OK'
    Write-Host '  Background notifications from Store apps may be reduced.' -ForegroundColor DarkGray
    Write-Host '  Visual effects apply after sign-out/restart.' -ForegroundColor DarkGray
}

# ------------------------------------------------------------------- power --
function Get-ActivePowerGuid {
    try {
        $out = (& powercfg.exe /getactivescheme 2>$null | Out-String)
        if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            return $Matches[1]
        }
    } catch { }
    return $null
}

function Get-PowerSettingIndex {
    param([string]$SchemeGuid, [string]$SubGroup, [string]$Setting)
    $ac = $null
    $dc = $null
    try {
        $out = (& powercfg.exe /query $SchemeGuid $SubGroup $Setting 2>$null | Out-String)
        $vals = @()
        foreach ($m in [regex]::Matches($out, '0x([0-9a-fA-F]+)')) {
            $vals += [Convert]::ToInt32($m.Groups[1].Value, 16)
        }
        if ($vals.Count -ge 2) {
            $ac = $vals[$vals.Count - 2]
            $dc = $vals[$vals.Count - 1]
        }
    } catch { }
    return [pscustomobject]@{ AC = $ac; DC = $dc }
}

function Invoke-PowerTweaks {
    if (-not (Assert-Admin)) { return }
    Ensure-SafetyPoint
    Write-Section 'Power plan'

    $constHigh     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $constBalanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $constSaver    = 'a1841308-3541-4fab-bc81-f71556f20b4a'
    $active = Get-ActivePowerGuid
    $target = $null

    # Keep custom/performance plans (for example a duplicated Ultimate
    # Performance plan). Only replace the known Balanced/Power saver plans.
    if ($active -and $active -ne $constBalanced -and $active -ne $constSaver) {
        $target = $active
        Write-Log 'An existing custom/high-performance plan is active; keeping it.' 'INFO'
    }
    else {
        try {
            $list = (& powercfg.exe /list 2>$null | Out-String)
            if ($list -match $constHigh) { $target = $constHigh }
        } catch { }

        if (-not $target) {
            try {
                $dup = (& powercfg.exe -duplicatescheme $constHigh 2>$null | Out-String)
                if ($dup -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                    $target = $Matches[1]
                }
            } catch { }
        }
    }

    if (-not $target) {
        Write-Log 'High performance power plan is not available on this system.' 'WARN'
        return
    }

    $min = Get-PowerSettingIndex -SchemeGuid $target -SubGroup 'SUB_PROCESSOR' -Setting 'PROCTHROTTLEMIN'
    Add-BackupAction -Type 'PowerScheme' -Data @{
        ActiveGuid = $active
        TargetGuid = $target
        MinAC      = $min.AC
        MinDC      = $min.DC
    }

    if ($script:DryRun) {
        Write-Log ('[dry] would keep/activate a performance plan ({0}) and set CPU minimum to 5%.' -f $target) 'INFO'
        return
    }

    try {
        # 5% minimum keeps the CPU responsive without pinning it at 100% all day.
        & powercfg.exe /setacvalueindex $target SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
        & powercfg.exe /setdcvalueindex $target SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
        & powercfg.exe /setactive $target | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Power plan: High performance (CPU minimum 5%).' 'OK'
            Write-Host '  Laptops: high performance can drain the battery faster.' -ForegroundColor DarkGray
        }
        else {
            Write-Log 'powercfg could not activate the high performance plan.' 'WARN'
        }
    }
    catch {
        Write-Log ('Power tweak failed: {0}' -f $_.Exception.Message) 'WARN'
    }
}

# ----------------------------------------------------------------- network --
function Invoke-NetworkTweaks {
    if (-not (Assert-Admin)) { return }
    Ensure-SafetyPoint
    Write-Section 'Network and multimedia responsiveness'

    $items = @(
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; N = 'NetworkThrottlingIndex'; V = -1; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; N = 'SystemResponsiveness'; V = 10; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; N = 'GPU Priority'; V = 8; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; N = 'Priority'; V = 6; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; N = 'Scheduling Category'; V = 'High'; T = 'String' }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; N = 'SFIO Priority'; V = 'High'; T = 'String' }
    )

    $n = Set-RegistryList -Items $items
    Write-Log ('Network/multimedia: {0} setting(s) processed.' -f $n) 'OK'

    if (-not $script:DryRun) {
        try {
            & ipconfig.exe /flushdns | Out-Null
            Write-Log 'DNS cache flushed.' 'OK'
        } catch { }
    }
}

# ------------------------------------------------------------- ultra preset --
function Disable-StartupEntry {
    param([string[]]$Patterns)

    if (-not $Patterns -or $Patterns.Count -eq 0) { return 0 }

    $paths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )

    $removed = 0
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if (-not $key) { continue }

        foreach ($name in @($key.GetValueNames())) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $match = $false
            foreach ($pattern in $Patterns) {
                if ($name -like $pattern) { $match = $true; break }
            }
            if (-not $match) { continue }

            if ($script:DryRun) {
                Write-Log ('[dry] startup entry would be disabled: {0}\{1}' -f $path, $name) 'INFO'
                continue
            }

            try {
                $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $kind = $key.GetValueKind($name).ToString()
                Add-BackupAction -Type 'Startup' -Key ('{0}|{1}' -f $path, $name) -Data @{
                    Path      = $path
                    Name      = $name
                    Value     = $value
                    ValueType = $kind
                }
                Remove-ItemProperty -LiteralPath $path -Name $name -Force -ErrorAction Stop
                $removed++
                Write-Log ('Startup entry disabled: {0}' -f $name) 'OK'
            }
            catch {
                Write-Log ('Could not disable startup entry {0}: {1}' -f $name, $_.Exception.Message) 'WARN'
            }
        }
    }
    return $removed
}

function Invoke-UltraTweaks {
    if (-not (Assert-Admin)) { return }
    Ensure-SafetyPoint
    Write-Section 'Ultra: maximum savings for very low-end PCs'

    $hw = Get-HardwareProfile
    Write-Log ('Hardware: {0} GB RAM, {1} core(s)/{2} thread(s), system disk {3}, laptop={4}.' -f `
        $hw.RamGB, $hw.Cores, $hw.Threads, $hw.Media, $hw.IsLaptop) 'INFO'

    # --- Shell / visual effects: the biggest perceived-speed win on old iGPUs.
    $shell = @(
        @{ P = 'HKCU:\Control Panel\Desktop'; N = 'DragFullWindows'; V = '0'; T = 'String' }
        @{ P = 'HKCU:\Control Panel\Desktop\WindowMetrics'; N = 'MinAnimate'; V = '0'; T = 'String' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'IconsOnly'; V = 1; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ListviewAlphaSelect'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ListviewShadow'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'TaskbarAnimations'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'DisallowShaking'; V = 1; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'RestartApps'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'SeparateProcess'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; N = 'StartupDelayInMSec'; V = 0; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; N = 'VisualFXSetting'; V = 2; T = 'DWord' }
        @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; N = 'EnableTransparency'; V = 0; T = 'DWord' }
    )
    $n = Set-RegistryList -Items $shell
    Write-Log ('Ultra shell: {0} setting(s) processed (animations/thumbnails off).' -f $n) 'OK'

    # --- Edge: no background process, no startup boost, sleep tabs sooner.
    $edge = @(
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'BackgroundModeEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'StartupBoostEnabled'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'SleepingTabsEnabled'; V = 1; T = 'DWord' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'SleepingTabsTimeout'; V = 300; T = 'DWord' }
    )
    [void](Set-RegistryList -Items $edge)
    Write-Log 'Edge: background mode and startup boost disabled; sleeping tabs enabled.' 'OK'

    # --- Memory / disk tuning.
    $memory = @(
        @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; N = 'ClearPageFileAtShutdown'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; N = 'LargeSystemCache'; V = 0; T = 'DWord' }
        @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; N = 'NtfsDisableLastAccessUpdate'; V = 1; T = 'DWord' }
    )

    if ($hw.RamGB -gt 0 -and $hw.RamGB -le 6.5) {
        # Merge service host processes. Saves real RAM on 2-4 GB machines,
        # at the cost of service isolation (revertable).
        $memory += @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control'; N = 'SvcHostSplitThresholdInKB'; V = -1; T = 'DWord' }
        Write-Log 'svchost splitting disabled to reduce RAM use (revert restores it).' 'OK'
    }
    else {
        Write-Log 'More than 6.5 GB RAM: keeping service isolation (svchost split).' 'INFO'
    }

    if ($hw.IsSSD) {
        $memory += @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'; N = 'EnablePrefetcher'; V = 0; T = 'DWord' }
        $memory += @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'; N = 'EnableSuperfetch'; V = 0; T = 'DWord' }
    }
    else {
        Write-Log ('Prefetch/Superfetch kept for {0} disk (helps mechanical drives).' -f $hw.Media) 'INFO'
    }

    [void](Set-RegistryList -Items $memory)

    # Delivery Optimization: download from Microsoft instead of random peers.
    [void](Set-RegistryList -Items @(
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; N = 'DODownloadMode'; V = 1; T = 'DWord' }
    ))

    # --- Services that are pure overhead on a weak, non-gaming machine.
    foreach ($name in @('XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc', 'wisvc', 'lfsvc')) {
        [void](Set-ServiceSetting -Name $name -StartupType 'Disabled')
    }

    if ($hw.RamGB -gt 0 -and $hw.RamGB -le 4.5) {
        [void](Set-ServiceSetting -Name 'WSearch' -StartupType 'Disabled')
        Write-Log 'Windows Search disabled: saves RAM on 4 GB-or-less PCs; Start search is less useful.' 'WARN'
    }
    else {
        Write-Log 'Windows Search kept (more than 4.5 GB RAM or unknown).' 'INFO'
    }

    # Keep Print Spooler: it is also used by "Microsoft Print to PDF".
    Write-Log 'Print Spooler kept so Print to PDF keeps working.' 'INFO'

    # --- Startup entries: remove the classic low-end RAM hogs, not user apps.
    $startupPatterns = @(
        'OneDrive', 'OneDriveSetup',
        'MicrosoftEdgeAutoLaunch*',
        'MicrosoftCopilotAutoLaunch*',
        'com.squirrel.Teams.Teams', 'Teams', 'MicrosoftTeams',
        'Cortana', 'Skype', 'Lync'
    )
    $removed = Disable-StartupEntry -Patterns $startupPatterns
    Write-Log ('Startup entries disabled: {0}.' -f $removed) 'OK'

    # --- Extra maintenance/telemetry tasks that are safe to stop.
    $tasks = @(
        @{ P = '\Microsoft\Windows\CloudExperienceHost\'; N = 'CreateObjectTask' }
        @{ P = '\Microsoft\Windows\DiskFootprint\'; N = 'Diagnostics' }
        @{ P = '\Microsoft\Windows\ApplicationData\'; N = 'DsSvcCleanup' }
        @{ P = '\Microsoft\Windows\PI\'; N = 'Sqm-Tasks' }
        @{ P = '\Microsoft\Windows\Power Efficiency Diagnostics\'; N = 'AnalyzeSystem' }
        @{ P = '\Microsoft\Windows\WindowsBackup\'; N = 'ConfigNotification' }
    )
    foreach ($t in $tasks) {
        [void](Disable-TaskTweak -TaskPath $t.P -TaskName $t.N)
    }
    Write-Log 'Ultra maintenance/telemetry tasks processed.' 'OK'

    Write-Host '  Ultra trade-offs: no window animations/thumbnails, fewer services,' -ForegroundColor DarkGray
    Write-Host '  OneDrive/Teams auto-start off, Xbox/Insider/Geolocation disabled.' -ForegroundColor DarkGray
}

# ----------------------------------------------------------------- cleanup --
function Get-FreeSpace {
    try {
        $drive = $env:SystemDrive
        $vol = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction Stop
        return [double]$vol.FreeSpace
    } catch {
        return 0
    }
}

function Clear-FolderContents {
    param([string]$Path)
    $result = [pscustomobject]@{ Removed = 0; Skipped = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $result.Removed++
        }
        catch {
            $result.Skipped++
        }
    }
    return $result
}

function Invoke-Cleanup {
    param([switch]$NoPrompt)

    if (-not (Assert-Admin)) { return }
    Write-Section 'Cleanup: temporary files'

    if ($script:DryRun) {
        Write-Log '[dry] would clear user temp, Windows temp and the Delivery Optimization cache.' 'INFO'
        return
    }

    if (-not $NoPrompt -and -not (Confirm-Continue 'Delete temp files? Apps recreate them when needed.')) {
        return
    }

    $before = Get-FreeSpace
    $removed = 0
    $skipped = 0

    foreach ($target in @(
        @{ Path = $env:TEMP; Label = 'User temp' }
        @{ Path = (Join-Path $env:SystemRoot 'Temp'); Label = 'Windows temp' }
    )) {
        $r = Clear-FolderContents -Path $target.Path
        $removed += $r.Removed
        $skipped += $r.Skipped
        Write-Log ('{0}: {1} item(s) removed, {2} in use.' -f $target.Label, $r.Removed, $r.Skipped) 'INFO'
    }

    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        try {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Write-Log 'Delivery Optimization cache cleared.' 'OK'
        }
        catch {
            Write-Log ('Delivery Optimization cache: {0}' -f $_.Exception.Message) 'WARN'
        }
    }

    $after = Get-FreeSpace
    $delta = $after - $before
    $script:ActionTouched++
    Write-Log ('Cleanup done: {0} item(s) removed; free space {1} -> {2} (+{3}).' -f `
        $removed, (Format-Bytes $before), (Format-Bytes $after), (Format-Bytes ([math]::Max(0, $delta)))) 'OK'
    if ($skipped -gt 0) {
        Write-Host ('  {0} file(s) were locked and skipped.' -f $skipped) -ForegroundColor DarkGray
    }
}

function Invoke-EmptyRecycleBin {
    if (-not (Assert-Admin)) { return }
    Write-Section 'Empty Recycle Bin'
    if (-not (Confirm-Continue 'Permanently delete everything in the Recycle Bin?')) { return }
    if ($script:DryRun) {
        Write-Log '[dry] would empty the Recycle Bin.' 'INFO'
        return
    }
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        $script:ActionTouched++
        Write-Log 'Recycle Bin emptied.' 'OK'
    }
    catch {
        Write-Log ('Could not empty Recycle Bin: {0}' -f $_.Exception.Message) 'WARN'
    }
}

function Invoke-DismCleanup {
    param([switch]$ResetBase)

    if (-not (Assert-Admin)) { return }
    Write-Section 'Component store cleanup (DISM)'
    if ($ResetBase) {
        Write-Host '  /ResetBase removes old update backups permanently.' -ForegroundColor Yellow
        Write-Host '  Installed updates can no longer be uninstalled afterwards.' -ForegroundColor Yellow
    }
    if (-not (Confirm-Continue 'Run DISM component cleanup? This can take 10-30 minutes.')) { return }

    $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    if ($ResetBase) { $dismArgs += '/ResetBase' }

    if ($script:DryRun) {
        Write-Log ('[dry] dism.exe {0}' -f ($dismArgs -join ' ')) 'INFO'
        return
    }

    try {
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\dism.exe') `
            -ArgumentList $dismArgs -Wait -NoNewWindow -PassThru -ErrorAction Stop
        if ($p.ExitCode -eq 0) {
            $script:ActionTouched++
            Write-Log 'DISM component cleanup completed.' 'OK'
        }
        else {
            Write-Log ('DISM exited with code {0}.' -f $p.ExitCode) 'WARN'
        }
    }
    catch {
        Write-Log ('DISM failed: {0}' -f $_.Exception.Message) 'WARN'
    }
}

# ---------------------------------------------------------------- advanced --
function Get-PrimaryMediaType {
    try {
        $letter = $env:SystemDrive.TrimEnd(':')
        $part = Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
        $physical = $disk | Get-PhysicalDisk -ErrorAction Stop
        if ($physical.MediaType) { return [string]$physical.MediaType }
    } catch { }
    try {
        $physical = Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1
        if ($physical.MediaType) { return [string]$physical.MediaType }
    } catch { }
    return 'Unknown'
}

function Get-HardwareProfile {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    $ramGB = 0
    if ($cs -and $cs.TotalPhysicalMemory) {
        $ramGB = [math]::Round(([double]$cs.TotalPhysicalMemory / 1GB), 1)
    }

    $media = Get-PrimaryMediaType
    $cores = 0
    $threads = 0
    if ($cpu) {
        $cores = [int]$cpu.NumberOfCores
        $threads = [int]$cpu.NumberOfLogicalProcessors
    }

    $battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0

    return [pscustomobject]@{
        RamGB    = $ramGB
        Cores    = $cores
        Threads  = $threads
        Media    = $media
        IsSSD    = ($media -like '*SSD*')
        IsHDD    = ($media -eq 'HDD')
        IsLaptop = $battery
    }
}

function Invoke-SysMainDisable {
    if (-not (Assert-Admin)) { return }
    $media = Get-PrimaryMediaType
    if ($media -eq 'HDD') {
        Write-Host '  HDD detected: SysMain (Superfetch) usually helps on mechanical disks.' -ForegroundColor Yellow
        if (-not (Confirm-Continue 'Disable SysMain anyway?')) { return }
    }
    Ensure-SafetyPoint
    Write-Section 'Disable SysMain (Superfetch)'
    [void](Set-ServiceSetting -Name 'SysMain' -StartupType 'Disabled')
    Write-Host '  Recommended on SSDs. Revert from the main menu if boot feels slower.' -ForegroundColor DarkGray
}

function Invoke-SearchDisable {
    if (-not (Assert-Admin)) { return }
    Write-Host '  Disabling Windows Search reduces indexing CPU/disk use,' -ForegroundColor Yellow
    Write-Host '  but Start menu and File Explorer search become less useful.' -ForegroundColor Yellow
    if (-not (Confirm-Continue 'Disable Windows Search indexing?')) { return }
    Ensure-SafetyPoint
    Write-Section 'Disable Windows Search indexing'
    [void](Set-ServiceSetting -Name 'WSearch' -StartupType 'Disabled')
}

function Invoke-XboxDisable {
    if (-not (Assert-Admin)) { return }
    Write-Host '  Xbox services are needed by Game Pass and some store games.' -ForegroundColor Yellow
    if (-not (Confirm-Continue 'Disable Xbox services? (skip if you game on PC)')) { return }
    Ensure-SafetyPoint
    Write-Section 'Disable Xbox services'
    foreach ($name in @('XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc')) {
        [void](Set-ServiceSetting -Name $name -StartupType 'Disabled')
    }
}

function Set-HibernateOff {
    if (-not (Assert-Admin)) { return }

    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    $hibernateEnabled = $null
    try {
        $hibernateEnabled = (Get-ItemProperty -LiteralPath $powerKey -Name 'HibernateEnabled' -ErrorAction Stop).HibernateEnabled
    } catch { }

    if ($null -ne $hibernateEnabled -and [int]$hibernateEnabled -eq 0) {
        Write-Log 'Hibernation is already disabled.' 'INFO'
        return
    }

    Ensure-SafetyPoint
    $fastStartup = $null
    try {
        $fastStartup = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Name 'HiberbootEnabled' -ErrorAction Stop).HiberbootEnabled
    } catch { }

    Add-BackupAction -Type 'Hibernate' -Data @{ Enabled = $true; FastStartup = $fastStartup }

    if ($script:DryRun) {
        Write-Log '[dry] would disable hibernation and Fast Startup.' 'INFO'
        return
    }

    Write-Section 'Disable hibernation / Fast Startup'
    try {
        & powercfg.exe /hibernate off | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Hibernation disabled; hiberfil.sys removed and disk space freed.' 'OK'
            Write-Host '  Cold boot may be slightly slower, but Fast Startup bugs are avoided.' -ForegroundColor DarkGray
        }
        else {
            Write-Log 'powercfg could not disable hibernation.' 'WARN'
        }
    }
    catch {
        Write-Log ('Hibernation tweak failed: {0}' -f $_.Exception.Message) 'WARN'
    }
}

function Remove-OneDriveApp {
    if (-not (Assert-Admin)) { return }

    $setup = Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'
    if (-not (Test-Path -LiteralPath $setup)) {
        $setup = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'
    }
    if (-not (Test-Path -LiteralPath $setup)) {
        Write-Log 'OneDrive setup executable was not found; it may already be uninstalled.' 'WARN'
        return
    }

    Write-Host '  This uninstalls the OneDrive app. Your files in the OneDrive folder' -ForegroundColor Yellow
    Write-Host '  are NOT deleted, and cloud data stays in your Microsoft account.' -ForegroundColor Yellow
    if (-not (Confirm-Continue 'Uninstall OneDrive?')) { return }
    if (-not (Confirm-Continue 'Really uninstall OneDrive? Reinstalling requires a download.')) { return }

    Ensure-SafetyPoint
    if ($script:DryRun) {
        Write-Log '[dry] would uninstall OneDrive.' 'INFO'
        return
    }

    try {
        Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -NoNewWindow -ErrorAction Stop
        $script:ActionTouched++
        Write-Log 'OneDrive uninstaller finished. Sign out to clear the tray icon.' 'OK'
    }
    catch {
        Write-Log ('OneDrive uninstall failed: {0}' -f $_.Exception.Message) 'WARN'
    }
}

function Disable-MouseAcceleration {
    if (-not (Assert-Admin)) { return }
    Ensure-SafetyPoint
    Write-Section 'Disable mouse acceleration'
    $items = @(
        @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseSpeed'; V = '0'; T = 'String' }
        @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseThreshold1'; V = '0'; T = 'String' }
        @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseThreshold2'; V = '0'; T = 'String' }
    )
    $n = Set-RegistryList -Items $items
    Write-Log ('Mouse acceleration: {0} setting(s) processed. Sign out to apply.' -f $n) 'OK'
}

# ------------------------------------------------------------------- revert --
function ConvertFrom-BackupValue {
    param($Value, [string]$Type)
    switch ($Type) {
        'DWord'       {
            $n = [int64]$Value
            if ($n -gt 2147483647) { $n -= 4294967296 }
            return [int]$n
        }
        'QWord'       { return [long]$Value }
        'Binary'      { return [byte[]]@($Value | ForEach-Object { [byte]$_ }) }
        'MultiString' { return [string[]]@($Value) }
        default       { return [string]$Value }
    }
}

function Get-BackupSessions {
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
}

function Restore-BackupSession {
    param([Parameter(Mandatory = $true)][string]$Folder)

    if (-not (Assert-Admin)) { return }

    $manifest = Join-Path $Folder 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Log 'This backup has no manifest.json.' 'ERROR'
        return
    }

    if (-not (Confirm-Continue ('Restore registry, services and tasks from {0}?' -f (Split-Path $Folder -Leaf)))) {
        return
    }

    if ($script:DryRun) {
        Write-Log ('[dry] would restore backup {0}' -f $Folder) 'INFO'
        return
    }

    try {
        $state = Get-Content -Raw -LiteralPath $manifest -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Write-Log ('Could not read backup manifest: {0}' -f $_.Exception.Message) 'ERROR'
        return
    }

    Write-Section 'Reverting WinSlim changes'
    $regOk = 0
    $regFail = 0
    $svcOk = 0
    $svcFail = 0
    $taskOk = 0
    $taskFail = 0
    $actionOk = 0
    $actionFail = 0

    foreach ($rec in @($state.Registry)) {
        if ($null -eq $rec) { continue }
        if ([string]$rec.Path -notmatch '^(HKCU|HKLM|HKCR|HKU|HKCC):\\') { continue }

        try {
            if ([bool]$rec.Existed) {
                $type = [string]$rec.ValueType
                if (@('DWord', 'String', 'QWord', 'MultiString', 'Binary', 'ExpandString') -notcontains $type) {
                    $type = 'String'
                }
                $value = ConvertFrom-BackupValue -Value $rec.Value -Type $type
                if (-not (Test-Path -LiteralPath $rec.Path)) {
                    New-Item -Path $rec.Path -Force -ErrorAction Stop | Out-Null
                }
                New-ItemProperty -LiteralPath $rec.Path -Name $rec.Name -Value $value `
                    -PropertyType $type -Force -ErrorAction Stop | Out-Null
            }
            else {
                if (Test-Path -LiteralPath $rec.Path) {
                    Remove-ItemProperty -LiteralPath $rec.Path -Name $rec.Name -Force -ErrorAction SilentlyContinue
                }
            }

            if (-not [bool]$rec.KeyExisted -and (Test-Path -LiteralPath $rec.Path)) {
                $k = Get-Item -LiteralPath $rec.Path -ErrorAction SilentlyContinue
                if ($k -and @($k.GetValueNames()).Count -eq 0 -and @($k.GetSubKeyNames()).Count -eq 0) {
                    Remove-Item -LiteralPath $rec.Path -Force -ErrorAction SilentlyContinue
                }
            }
            $regOk++
        }
        catch {
            $regFail++
            Write-Log ('Registry revert failed for {0}\{1}: {2}' -f $rec.Path, $rec.Name, $_.Exception.Message) 'WARN'
        }
    }

    foreach ($rec in @($state.Services)) {
        if ($null -eq $rec) { continue }
        $svc = Get-Service -Name $rec.Name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        try {
            Set-Service -Name $rec.Name -StartupType $rec.StartType -ErrorAction Stop
            if ($rec.Status -eq 'Running' -and (Get-Service -Name $rec.Name).Status -ne 'Running') {
                Start-Service -Name $rec.Name -ErrorAction SilentlyContinue
            }
            $svcOk++
        }
        catch {
            $svcFail++
            Write-Log ('Service revert failed for {0}: {1}' -f $rec.Name, $_.Exception.Message) 'WARN'
        }
    }

    foreach ($rec in @($state.Tasks)) {
        if ($null -eq $rec) { continue }
        try {
            $task = Get-ScheduledTask -TaskPath $rec.TaskPath -TaskName $rec.TaskName -ErrorAction SilentlyContinue
            if ($task -and $rec.State -ne 'Disabled') {
                Enable-ScheduledTask -TaskPath $rec.TaskPath -TaskName $rec.TaskName -ErrorAction Stop | Out-Null
            }
            $taskOk++
        }
        catch {
            $taskFail++
            Write-Log ('Task revert failed for {0}{1}: {2}' -f $rec.TaskPath, $rec.TaskName, $_.Exception.Message) 'WARN'
        }
    }

    foreach ($action in @($state.Actions)) {
        if ($null -eq $action) { continue }
        $data = $action.Data
        try {
            switch ([string]$action.Type) {
                'PowerScheme' {
                    if ($data.TargetGuid -and $null -ne $data.MinAC) {
                        & powercfg.exe /setacvalueindex ([string]$data.TargetGuid) SUB_PROCESSOR PROCTHROTTLEMIN ([string]$data.MinAC) | Out-Null
                    }
                    if ($data.TargetGuid -and $null -ne $data.MinDC) {
                        & powercfg.exe /setdcvalueindex ([string]$data.TargetGuid) SUB_PROCESSOR PROCTHROTTLEMIN ([string]$data.MinDC) | Out-Null
                    }
                    if ($data.ActiveGuid) {
                        & powercfg.exe /setactive ([string]$data.ActiveGuid) | Out-Null
                    }
                }
                'Hibernate' {
                    if ([bool]$data.Enabled) {
                        & powercfg.exe /hibernate on | Out-Null
                        if ($null -ne $data.FastStartup) {
                            $fastKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
                            if (-not (Test-Path -LiteralPath $fastKey)) { New-Item -Path $fastKey -Force | Out-Null }
                            New-ItemProperty -LiteralPath $fastKey -Name 'HiberbootEnabled' `
                                -Value ([int]$data.FastStartup) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                        }
                    }
                }
                'Startup' {
                    if ($data.Path -and $data.Name) {
                        $startPath = [string]$data.Path
                        $startType = [string]$data.ValueType
                        if (@('DWord', 'String', 'QWord', 'MultiString', 'Binary', 'ExpandString') -notcontains $startType) {
                            $startType = 'String'
                        }
                        if (-not (Test-Path -LiteralPath $startPath)) {
                            New-Item -Path $startPath -Force -ErrorAction Stop | Out-Null
                        }
                        $startValue = ConvertFrom-BackupValue -Value $data.Value -Type $startType
                        New-ItemProperty -LiteralPath $startPath -Name ([string]$data.Name) -Value $startValue `
                            -PropertyType $startType -Force -ErrorAction Stop | Out-Null
                    }
                }
            }
            $actionOk++
        }
        catch {
            $actionFail++
            Write-Log ('Action revert failed ({0}): {1}' -f $action.Type, $_.Exception.Message) 'WARN'
        }
    }

    Write-Log ('Revert finished: registry {0}/{1}, services {2}/{3}, tasks {4}/{5}, actions {6}/{7}.' -f `
        $regOk, ($regOk + $regFail), $svcOk, ($svcOk + $svcFail), $taskOk, ($taskOk + $taskFail), $actionOk, ($actionOk + $actionFail)) 'OK'
    Write-Host '  Removed Store apps and temp-file cleanup are not restored by this revert.' -ForegroundColor Yellow
    Write-Host '  Use "S" in the revert menu to open Windows System Restore if needed.' -ForegroundColor Yellow

    try {
        Set-Content -LiteralPath (Join-Path $Folder 'restored.txt') -Value (Get-Date).ToString('o') -Encoding UTF8
    } catch { }

    Reset-SessionBackup
}

function Show-RevertMenu {
    while ($true) {
        $sessions = @(Get-BackupSessions)
        Write-Host ''
        Write-Host '  Revert changes from a previous WinSlim run' -ForegroundColor Cyan
        Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

        if ($sessions.Count -eq 0) {
            Write-Host '  No backups found yet.' -ForegroundColor Gray
        }
        else {
            $limit = [math]::Min(10, $sessions.Count)
            for ($i = 0; $i -lt $limit; $i++) {
                $folder = $sessions[$i]
                $changes = '?'
                try {
                    $m = Get-Content -Raw -LiteralPath (Join-Path $folder.FullName 'manifest.json') -ErrorAction Stop | ConvertFrom-Json
                    $changes = @($m.Registry).Count + @($m.Services).Count + @($m.Tasks).Count + @($m.Actions).Count
                } catch { }
                $mark = ''
                if (Test-Path -LiteralPath (Join-Path $folder.FullName 'restored.txt')) { $mark = ' [restored]' }
                Write-Host ('  [{0}] {1}   entries={2}{3}' -f ($i + 1), $folder.Name, $changes, $mark)
            }
        }

        Write-Host '  [S] Open Windows System Restore'
        Write-Host '  [0] Back'
        $choice = Read-Host '  Select'
        if ($null -eq $choice) { return }
        $choice = $choice.Trim().ToUpperInvariant()

        if ($choice -eq '0' -or $choice -eq '') { return }
        if ($choice -eq 'S') {
            try { Start-Process -FilePath 'rstrui.exe' -ErrorAction Stop | Out-Null }
            catch { Write-Log 'Could not open System Restore.' 'WARN' }
            continue
        }

        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le [math]::Min(10, $sessions.Count)) {
            Restore-BackupSession -Folder $sessions[$index - 1].FullName
            Wait-ForKey
            return
        }
    }
}

# ------------------------------------------------------------------- report --
function Write-ReportLine {
    param([string]$Label, $Value)
    Write-Host ('  {0,-22} {1}' -f $Label, $Value)
}

function Invoke-SystemReport {
    Write-Section 'System report'

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $os) {
        Write-Log 'Could not read operating system information.' 'ERROR'
        return
    }

    $ramTotal = 0
    $ramFree = 0
    if ($cs) { $ramTotal = [double]$cs.TotalPhysicalMemory }
    if ($os) { $ramFree = [double]$os.FreePhysicalMemory * 1KB }

    $uptime = (Get-Date) - $os.LastBootUpTime

    Write-Host ''
    Write-Host '  System' -ForegroundColor Cyan
    Write-ReportLine 'Windows' ('{0} (build {1})' -f $os.Caption, $os.BuildNumber)
    Write-ReportLine 'Computer' ('{0} {1}' -f $cs.Manufacturer, $cs.Model)
    if ($cpu) {
        Write-ReportLine 'CPU' ('{0} ({1}C/{2}T)' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    }
    Write-ReportLine 'Memory' ('{0:N1} GB total, {1:N1} GB free' -f ($ramTotal / 1GB), ($ramFree / 1GB))
    Write-ReportLine 'Uptime' ('{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes)

    $modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    if ($modules.Count -gt 0) {
        $moduleText = ($modules | ForEach-Object {
            '{0:N0} GB @ {1} MHz' -f ([double]$_.Capacity / 1GB), $_.Speed
        }) -join ' + '
        Write-ReportLine 'RAM modules' $moduleText
    }

    $gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'Basic Display|Remote' } | Select-Object -First 1)
    if ($gpu.Count -gt 0) {
        Write-ReportLine 'GPU' $gpu[0].Name
    }

    $media = Get-PrimaryMediaType
    $ultraFit = (($ramTotal -gt 0 -and $ramTotal -le 4.5GB) -or $media -eq 'HDD' -or ($cpu -and [int]$cpu.NumberOfCores -le 2))
    Write-ReportLine 'Ultra preset' $(if ($ultraFit) { 'recommended (very low-end hardware)' } else { 'optional' })
    $vol = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction SilentlyContinue
    if ($vol) {
        $usedPct = 0
        if ($vol.Size -gt 0) { $usedPct = [math]::Round((($vol.Size - $vol.FreeSpace) / $vol.Size) * 100) }
        Write-ReportLine 'System disk' ('{0} {1}, {2} free of {3} ({4}% used)' -f `
            $env:SystemDrive, $media, (Format-Bytes $vol.FreeSpace), (Format-Bytes $vol.Size), $usedPct)
    }
    else {
        Write-ReportLine 'System disk' $media
    }

    $physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    if ($physical.Count -gt 0) {
        $diskNames = ($physical | ForEach-Object {
            '{0} [{1}, {2}]' -f $_.FriendlyName, $_.MediaType, (Format-Bytes $_.Size)
        }) -join '; '
        Write-ReportLine 'Physical disks' $diskNames
    }

    $plan = Get-ActivePowerGuid
    if ($plan) {
        $planText = $plan
        try {
            $planOut = (& powercfg.exe /getactivescheme 2>$null | Out-String).Trim()
            if ($planOut -match '\(([^)]+)\)') { $planText = '{0} ({1})' -f $Matches[1], $plan }
        } catch { }
        Write-ReportLine 'Power plan' $planText
    }

    $pending = $false
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        if (Test-Path -LiteralPath $key) { $pending = $true }
    }
    $pfro = $null
    try {
        $pfro = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name 'PendingFileRenameOperations' -ErrorAction Stop).PendingFileRenameOperations
    } catch { }
    if ($pfro) { $pending = $true }
    Write-ReportLine 'Reboot pending' $pending

    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    if ($startup.Count -gt 0) {
        Write-Host ''
        Write-Host '  Startup entries' -ForegroundColor Cyan
        $startup | Select-Object Name,
            @{ N = 'Scope'; E = { if ($_.Location -match 'HKLM|Common Startup') { 'Machine' } else { 'User' } } } |
            Format-Table -AutoSize | Out-String -Width 110 | Write-Host
    }

    Write-Host '  Top memory processes' -ForegroundColor Cyan
    Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending |
        Select-Object -First 8 @{ N = 'Process'; E = { $_.ProcessName } },
            @{ N = 'RAM (MB)'; E = { [math]::Round($_.WorkingSet64 / 1MB) } } |
        Format-Table -AutoSize | Out-String -Width 100 | Write-Host

    # Recommendations tuned to the machine, not generic snake oil.
    $tips = New-Object System.Collections.Generic.List[string]
    if ($ramTotal -gt 0 -and $ramTotal -le 8.5GB) {
        $tips.Add('8 GB or less RAM: use the Balanced preset, close browser tabs, and limit background apps. A RAM upgrade is the biggest fix.')
    }
    if ($ramTotal -gt 0 -and $ramTotal -le 4.5GB) {
        $tips.Add('4 GB or less RAM: the Ultra preset is built for this machine, but it disables Search on 4 GB and below. Restart afterwards.')
    }
    if ($media -eq 'HDD') {
        $tips.Add('Mechanical HDD detected: an SSD is by far the biggest upgrade. Keep SysMain/Windows Search enabled on HDDs.')
    }
    elseif ($media -like '*SSD*') {
        $tips.Add('SSD detected: disabling SysMain is usually safe, and hibernation off frees several GB.')
    }
    if ($vol -and $vol.Size -gt 0 -and (($vol.Size - $vol.FreeSpace) / $vol.Size) -gt 0.85) {
        $tips.Add('System drive is over 85% full: run Cleanup and move large files to another drive.')
    }
    if ($startup.Count -ge 8) {
        $tips.Add(('{0} startup entries found: review Task Manager > Startup apps.' -f $startup.Count))
    }
    if ($uptime.TotalDays -ge 7) {
        $tips.Add('Uptime is over 7 days: a restart clears leaked memory and finishes pending updates.')
    }
    if (@(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0) {
        $tips.Add('Laptop detected: High performance drains battery faster; the tool sets CPU minimum to 5% to reduce heat.')
    }
    if ([int]$os.BuildNumber -ge 22000) {
        $tips.Add('Windows 11: the privacy module also disables Copilot, Recall and Widgets where supported.')
    }
    if ($pending) {
        $tips.Add('A reboot is pending. Restart before heavy tweaking to avoid Update conflicts.')
    }
    $tips.Add('Honest expectation: tweaks reduce background noise and free some RAM/CPU. An SSD and more RAM help far more.')

    Write-Host ''
    Write-Host '  Recommendations' -ForegroundColor Cyan
    foreach ($tip in $tips) {
        Write-Host ('   - {0}' -f $tip) -ForegroundColor Gray
    }
}

# --------------------------------------------------------------- UI / presets --
function Show-Banner {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ('   WinSlim  v{0}  -  Windows optimizer for low-end PCs' -f $script:Version) -ForegroundColor Cyan
    Write-Host '   Registry/service/task tweaks are reversible.' -ForegroundColor DarkGray
    Write-Host '   No Defender / Firewall / Windows Update tampering.' -ForegroundColor DarkGray
    Write-Host '  ============================================================' -ForegroundColor DarkCyan

    $mode = 'READ-ONLY (not elevated)'
    if ($script:DryRun) { $mode = 'DRY RUN (nothing is written)' }
    elseif ($script:IsAdmin) { $mode = 'ADMIN' }
    Write-Host ('   Mode: {0}' -f $mode) -ForegroundColor DarkGray
}

function Get-PresetDetails {
    param([string]$Name)
    switch ($Name) {
        'Safe' {
            return @(
                'Privacy/telemetry registry hardening'
                'Disable DiagTrack and telemetry scheduled tasks'
                'No app removal, no power or UI changes'
            )
        }
        'Balanced' {
            return @(
                'Everything in Safe'
                'Remove curated consumer/junk Store apps'
                'Background apps off, Game DVR off, UI animations reduced'
                'High performance power plan with CPU minimum 5%'
                'Multimedia/network responsiveness tweaks'
            )
        }
        'Aggressive' {
            return @(
                'Everything in Balanced'
                'Disable hibernation/Fast Startup (frees disk space)'
                'Disable SysMain on SSDs only'
                'Quick temp-file cleanup'
            )
        }
        'Ultra' {
            return @(
                'Everything in Aggressive, plus deeper savings'
                'Animations, transparency and thumbnails off'
                'Xbox, Insider and Geolocation services disabled'
                'Windows Search off on PCs with 4 GB RAM or less'
                'svchost processes merged to save RAM'
                'OneDrive/Teams/Edge auto-start entries disabled'
                'Edge background mode + startup boost off'
                'Removes Widgets, Mail, Phone Link, Dev Home, Movies & TV'
                'Best for 2-4 GB RAM / old dual-core machines'
            )
        }
    }
    return @()
}

function Invoke-PresetFlow {
    param([Parameter(Mandatory = $true)][ValidateSet('Safe', 'Balanced', 'Aggressive', 'Ultra')][string]$Name)

    if (-not (Assert-Admin)) { return }

    Write-Section ('Preset: {0}' -f $Name.ToUpperInvariant())
    foreach ($line in (Get-PresetDetails -Name $Name)) {
        Write-Host ('   - {0}' -f $line) -ForegroundColor Gray
    }
    if (@('Balanced', 'Aggressive', 'Ultra') -contains $Name) {
        Write-Host '  Removed Store apps are not automatically restored by Revert.' -ForegroundColor DarkGray
        Write-Host '  A System Restore point is attempted before the first change.' -ForegroundColor DarkGray
    }

    if (-not $script:DryRun -and -not (Confirm-Continue ('Apply the {0} preset?' -f $Name))) {
        return
    }

    $oldAuto = $script:AutoYes
    $script:AutoYes = $true
    try {
        Invoke-PrivacyTweaks
        Save-BackupState
        Invoke-ServicesAndTasks
        Save-BackupState

        if (@('Balanced', 'Aggressive', 'Ultra') -contains $Name) {
            if ($Name -eq 'Ultra') { Invoke-Debloat -NoPrompt -Ultra }
            else { Invoke-Debloat -NoPrompt }
            Save-BackupState
            Invoke-PerformanceTweaks
            Save-BackupState
            Invoke-PowerTweaks
            Save-BackupState
            Invoke-NetworkTweaks
            Save-BackupState
        }

        if (@('Aggressive', 'Ultra') -contains $Name) {
            Set-HibernateOff
            Save-BackupState
            $media = Get-PrimaryMediaType
            if ($media -like '*SSD*') {
                Write-Log 'SSD detected: disabling SysMain.' 'INFO'
                [void](Set-ServiceSetting -Name 'SysMain' -StartupType 'Disabled')
            }
            else {
                Write-Log ('SysMain kept ({0} disk): Superfetch helps mechanical disks.' -f $media) 'WARN'
            }
            Invoke-Cleanup -NoPrompt
        }

        if ($Name -eq 'Ultra') {
            Invoke-UltraTweaks
            Save-BackupState
        }
    }
    catch {
        Write-Log ('Preset failed: {0}' -f $_.Exception.Message) 'ERROR'
    }
    finally {
        $script:AutoYes = $oldAuto
        Save-BackupState
    }

    Write-Section 'Preset complete'
    Show-SessionSummary
    if (-not $script:DryRun) {
        Write-Host '  Review the log, then sign out or restart.' -ForegroundColor Yellow
    }
}

function Complete-MenuAction {
    Save-BackupState
    Show-SessionSummary
    Wait-ForKey
}

function Show-AdvancedMenu {
    while ($true) {
        Clear-Host
        Show-Banner
        Write-Host ''
        Write-Host '  Advanced tweaks (each one is optional and reversible)' -ForegroundColor Cyan
        Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '  [1] Disable SysMain / Superfetch        (recommended on SSD)'
        Write-Host '  [2] Disable Windows Search indexing     (hurts search)'
        Write-Host '  [3] Disable Xbox services               (not for gamers)'
        Write-Host '  [4] Disable hibernation / Fast Startup  (frees disk)'
        Write-Host '  [5] Uninstall OneDrive app              (files stay)'
        Write-Host '  [6] Disable mouse acceleration          (sign out to apply)'
        Write-Host '  [0] Back'
        Write-Host ''
        Write-Host '  Revert any of these later from the main menu.' -ForegroundColor DarkGray
        $choice = Read-Host '  Select'

        switch (([string]$choice).Trim()) {
            '1' { Invoke-SysMainDisable; Complete-MenuAction }
            '2' { Invoke-SearchDisable; Complete-MenuAction }
            '3' { Invoke-XboxDisable; Complete-MenuAction }
            '4' { Set-HibernateOff; Complete-MenuAction }
            '5' { Remove-OneDriveApp; Complete-MenuAction }
            '6' { Disable-MouseAcceleration; Complete-MenuAction }
            '0' { return }
            ''  { return }
        }
    }
}

function Show-CleanupMenu {
    while ($true) {
        Clear-Host
        Show-Banner
        Write-Host ''
        Write-Host '  Cleanup tools' -ForegroundColor Cyan
        Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '  [1] Quick cleanup (temp files + Delivery Optimization cache)'
        Write-Host '  [2] Empty the Recycle Bin (permanent)'
        Write-Host '  [3] DISM component cleanup (safe, 10-30 min)'
        Write-Host '  [4] DISM deep cleanup /ResetBase (cannot uninstall updates)'
        Write-Host '  [0] Back'
        $choice = Read-Host '  Select'

        switch (([string]$choice).Trim()) {
            '1' { Invoke-Cleanup; Complete-MenuAction }
            '2' { Invoke-EmptyRecycleBin; Complete-MenuAction }
            '3' { Invoke-DismCleanup; Complete-MenuAction }
            '4' { Invoke-DismCleanup -ResetBase; Complete-MenuAction }
            '0' { return }
            ''  { return }
        }
    }
}

function Show-CustomMenu {
    while ($true) {
        Clear-Host
        Show-Banner
        Write-Host ''
        Write-Host '  Custom tweaks' -ForegroundColor Cyan
        Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '  [1] Privacy and telemetry'
        Write-Host '  [2] Debloat consumer/Store apps'
        Write-Host '  [3] Background services and telemetry tasks'
        Write-Host '  [4] Performance and UI'
        Write-Host '  [5] Power plan'
        Write-Host '  [6] Network and multimedia'
        Write-Host '  [7] Cleanup tools'
        Write-Host '  [8] Advanced / risky tweaks'
        Write-Host '  [0] Back'
        $choice = Read-Host '  Select'

        switch (([string]$choice).Trim()) {
            '1' { Invoke-PrivacyTweaks; Complete-MenuAction }
            '2' { Invoke-Debloat; Complete-MenuAction }
            '3' { Invoke-ServicesAndTasks; Complete-MenuAction }
            '4' { Invoke-PerformanceTweaks; Complete-MenuAction }
            '5' { Invoke-PowerTweaks; Complete-MenuAction }
            '6' { Invoke-NetworkTweaks; Complete-MenuAction }
            '7' { Show-CleanupMenu }
            '8' { Show-AdvancedMenu }
            '0' { return }
            ''  { return }
        }
    }
}

function Open-DataFolders {
    if (Test-Path -LiteralPath $script:BackupRoot) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:BackupRoot) -ErrorAction SilentlyContinue
    }
    else {
        Write-Host '  No backup folder exists yet.' -ForegroundColor DarkGray
    }
    if ($script:LogFile) {
        $logDir = Split-Path -Parent $script:LogFile
        if (Test-Path -LiteralPath $logDir) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $logDir) -ErrorAction SilentlyContinue
        }
    }
}

function Show-MainMenu {
    while ($true) {
        Clear-Host
        Show-Banner
        Write-Host ''
        Write-Host '  [1] System report and recommendations'
        Write-Host '  [2] SAFE preset      - privacy/telemetry only'
        Write-Host '  [3] BALANCED preset  - recommended for weak PCs' -ForegroundColor Green
        Write-Host '  [4] AGGRESSIVE preset - more changes, read trade-offs'
        Write-Host '  [5] ULTRA preset     - 2-4 GB RAM, maximum savings' -ForegroundColor Yellow
        Write-Host '  [C] Custom tweaks...'
        Write-Host '  [R] Revert a previous run'
        Write-Host '  [O] Open backup/log folders'
        Write-Host '  [Q] Quit'
        Write-Host ''
        if ($script:DryRun) {
            Write-Host '  Dry-run mode: no changes are written.' -ForegroundColor DarkGray
        }
        elseif ($script:IsAdmin) {
            Write-Host ('  Backups: {0}' -f $script:BackupRoot) -ForegroundColor DarkGray
        }
        else {
            Write-Host '  Not elevated: actions are disabled (use without -NoElevate).' -ForegroundColor Yellow
        }

        $choice = Read-Host '  Select'
        if ($null -eq $choice) { return }
        $choice = $choice.Trim().ToUpperInvariant()

        switch ($choice) {
            '1' { Invoke-SystemReport; Wait-ForKey }
            '2' { Invoke-PresetFlow -Name 'Safe'; Wait-ForKey }
            '3' { Invoke-PresetFlow -Name 'Balanced'; Wait-ForKey }
            '4' { Invoke-PresetFlow -Name 'Aggressive'; Wait-ForKey }
            '5' { Invoke-PresetFlow -Name 'Ultra'; Wait-ForKey }
            'C' { Show-CustomMenu }
            'R' { Show-RevertMenu }
            'O' { Open-DataFolders; Wait-ForKey }
            'Q' { return }
            ''  { }
        }
    }
}

# --------------------------------------------------------------------- main --
Initialize-Session

if ($Report) {
    Invoke-SystemReport
    exit 0
}

if ($Preset -ne 'Menu') {
    if (-not $script:IsAdmin -and -not $script:DryRun) {
        Write-Log 'Administrator rights are required for preset runs. Launch WinSlim as administrator.' 'ERROR'
        exit 1
    }

    Invoke-PresetFlow -Name $Preset

    if (-not $script:DryRun -and -not $Yes) {
        Wait-ForKey
    }
    exit 0
}

try {
    Show-MainMenu
}
catch {
    Write-Log ('Unexpected error: {0}' -f $_.Exception.Message) 'ERROR'
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
}
finally {
    Save-BackupState
}









