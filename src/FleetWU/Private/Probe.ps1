# The probe runs ON the target machine (locally, or remotely through Invoke-Command)
# and returns raw facts. It is self-contained (no module functions), works on
# Windows PowerShell 5.1 and PowerShell 7, and is READ-ONLY: it only uses
# Get-ItemProperty, Test-Path, Get-CimInstance and the Windows Update Agent
# history query. tests/ReadOnly.Tests.ps1 enforces this.

$script:FWProbe = {
    param([int]$HistoryMax = 200)

    $ErrorActionPreference = 'Stop'
    $errors = New-Object System.Collections.Generic.List[string]

    function Read-RegistryValue([string]$Path, [string[]]$Names) {
        $out = @{}
        if (-not (Test-Path -LiteralPath $Path)) { return $out }
        $item = Get-ItemProperty -LiteralPath $Path
        foreach ($n in $Names) {
            if ($null -ne $item.PSObject.Properties[$n]) { $out[$n] = $item.$n }
        }
        return $out
    }

    function ConvertTo-IsoDate($Value) {
        if ($null -eq $Value) { return $null }
        if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
        return [string]$Value
    }

    $facts = [ordered]@{
        ComputerName  = $env:COMPUTERNAME
        CollectedAt   = (Get-Date).ToUniversalTime().ToString('o')
        ProbeVersion  = '1.0.0'
        Os            = $null
        Services      = @{}
        Policy        = @{}
        Pause         = @{}
        Reboot        = @{}
        History       = @()
        HistorySource = 'None'
        Errors        = $null
    }

    # Operating system
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $cv = Read-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' @('DisplayVersion', 'UBR', 'EditionID')
        $facts.Os = @{
            Caption        = [string]$os.Caption
            Version        = [string]$os.Version
            Build          = [string]$os.BuildNumber
            UBR            = $cv['UBR']
            DisplayVersion = $cv['DisplayVersion']
            LastBootUpTime = ConvertTo-IsoDate $os.LastBootUpTime
        }
    } catch { $errors.Add("Os: $($_.Exception.Message)") }

    # Update services (start mode only)
    try {
        foreach ($name in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc') {
            $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'"
            $facts.Services[$name] = if ($svc) { [string]$svc.StartMode } else { 'Missing' }
        }
    } catch { $errors.Add("Services: $($_.Exception.Message)") }

    # Group Policy / MDM-written Windows Update policy
    try {
        $wu = Read-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' @(
            'WUServer', 'WUStatusServer', 'DoNotConnectToWindowsUpdateInternetLocations', 'DisableDualScan',
            'DeferQualityUpdates', 'DeferQualityUpdatesPeriodInDays', 'DeferFeatureUpdates', 'DeferFeatureUpdatesPeriodInDays',
            'PauseQualityUpdatesStartTime', 'PauseFeatureUpdatesStartTime', 'TargetReleaseVersion', 'TargetReleaseVersionInfo', 'ProductVersion')
        $au = Read-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' @(
            'NoAutoUpdate', 'AUOptions', 'UseWUServer', 'ScheduledInstallDay', 'ScheduledInstallTime', 'NoAutoRebootWithLoggedOnUsers')
        foreach ($k in $au.Keys) { $wu[$k] = $au[$k] }
        $facts.Policy = $wu
    } catch { $errors.Add("Policy: $($_.Exception.Message)") }

    # User/admin pause from Settings
    try {
        $facts.Pause = Read-RegistryValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' @(
            'PauseUpdatesExpiryTime', 'PauseQualityUpdatesEndTime', 'PauseFeatureUpdatesEndTime')
    } catch { $errors.Add("Pause: $($_.Exception.Message)") }

    # Pending reboot markers
    try {
        $facts.Reboot = @{
            WindowsUpdate = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
            ComponentBasedServicing = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        }
    } catch { $errors.Add("Reboot: $($_.Exception.Message)") }

    # Update history: Windows Update Agent (read-only query), fallback Get-CimInstance Win32_QuickFixEngineering
    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()
        $take = [Math]::Min($count, $HistoryMax)
        $items = @()
        if ($take -gt 0) {
            foreach ($h in $searcher.QueryHistory(0, $take)) {
                $items += [pscustomobject]@{
                    Title      = [string]$h.Title
                    Date       = ConvertTo-IsoDate $h.Date
                    ResultCode = [int]$h.ResultCode
                    Operation  = [int]$h.Operation
                    HResult    = ('0x{0:X8}' -f [int]$h.HResult)
                }
            }
        }
        $facts.History = $items
        $facts.HistorySource = 'WUA'
    } catch {
        $errors.Add("History(WUA): $($_.Exception.Message)")
        try {
            $facts.History = @(Get-CimInstance -ClassName Win32_QuickFixEngineering | Where-Object { $_.InstalledOn } | ForEach-Object {
                    [pscustomobject]@{ Title = "$($_.Description) $($_.HotFixID)"; Date = ConvertTo-IsoDate $_.InstalledOn; ResultCode = 2; Operation = 1; HResult = '0x00000000' }
                })
            $facts.HistorySource = 'QFE'
        } catch { $errors.Add("History(QFE): $($_.Exception.Message)") }
    }

    $facts.Errors = @($errors)
    [pscustomobject]$facts
}

function Get-FWProbe {
    <# Returns the read-only probe script block. #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()
    $script:FWProbe
}
