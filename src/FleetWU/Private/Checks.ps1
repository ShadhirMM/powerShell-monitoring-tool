# Checks are pure functions: facts + config + time in, one result out.
# Status: OK | WARNING | ALERT. Overall status = the worst one.

$script:FWStatusRank = @{ OK = 0; WARNING = 1; ALERT = 2 }

function Get-FWWorstStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Status)
    $worst = 'OK'
    foreach ($s in $Status) { if ($script:FWStatusRank[$s] -gt $script:FWStatusRank[$worst]) { $worst = $s } }
    $worst
}

function New-FWCheck {
    [CmdletBinding()]
    param([string]$Check, [string]$Status, [string]$Detail)
    [pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail }
}

function ConvertTo-FWDate {
    <# Parses registry/WUA date values to UTC [datetime]; $null if empty or unparsable. #>
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    $null
}

function Get-FWValue {
    # Safe lookup in a hashtable or (deserialized) object.
    param($Container, [string]$Name)
    if ($null -eq $Container) { return $null }
    if ($Container -is [System.Collections.IDictionary]) { return $Container[$Name] }
    $prop = $Container.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    $null
}

function Test-FWUpdateService {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'All checks share one signature (Facts, Config, Now) so Invoke-FWCheck can call them uniformly.')]
    [CmdletBinding()]
    param($Facts, [hashtable]$Config, [datetime]$Now)
    $svc = $Facts.Services
    $modes = foreach ($n in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc') { "${n}: $(Get-FWValue $svc $n)" }
    $detail = $modes -join ', '
    if (-not (Get-FWValue $svc 'wuauserv')) {
        return New-FWCheck 'UpdateServices' 'WARNING' 'Service state could not be read'
    }
    foreach ($n in 'wuauserv', 'UsoSvc') {
        $m = Get-FWValue $svc $n
        if ($m -in 'Disabled', 'Missing') { return New-FWCheck 'UpdateServices' 'ALERT' "$n is $m ($detail)" }
    }
    if ((Get-FWValue $svc 'WaaSMedicSvc') -eq 'Disabled') { return New-FWCheck 'UpdateServices' 'WARNING' "WaaSMedicSvc (update repair) is disabled ($detail)" }
    New-FWCheck 'UpdateServices' 'OK' "Update services enabled ($detail)"
}

function Test-FWAutomaticUpdate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'All checks share one signature (Facts, Config, Now) so Invoke-FWCheck can call them uniformly.')]
    [CmdletBinding()]
    param($Facts, [hashtable]$Config, [datetime]$Now)
    $p = $Facts.Policy
    if ((Get-FWValue $p 'NoAutoUpdate') -eq 1) { return New-FWCheck 'AutomaticUpdates' 'ALERT' 'Policy NoAutoUpdate=1: automatic updates are turned off' }
    $au = Get-FWValue $p 'AUOptions'
    switch ("$au") {
        '' { return New-FWCheck 'AutomaticUpdates' 'OK' 'No policy: Windows default (download and install automatically)' }
        '4' { return New-FWCheck 'AutomaticUpdates' 'OK' 'AUOptions=4: download and install automatically' }
        '2' { return New-FWCheck 'AutomaticUpdates' 'WARNING' 'AUOptions=2: notify before download; installs need a person' }
        '3' { return New-FWCheck 'AutomaticUpdates' 'WARNING' 'AUOptions=3: download automatically, notify to install' }
        '5' { return New-FWCheck 'AutomaticUpdates' 'WARNING' 'AUOptions=5: local administrator chooses the setting' }
        '7' { return New-FWCheck 'AutomaticUpdates' 'WARNING' 'AUOptions=7: notify to install, notify to restart' }
        default { return New-FWCheck 'AutomaticUpdates' 'WARNING' "Unrecognised AUOptions value '$au'" }
    }
}

function Test-FWUpdatePause {
    [CmdletBinding()]
    param($Facts, [hashtable]$Config, [datetime]$Now)
    $latest = $null
    foreach ($n in 'PauseUpdatesExpiryTime', 'PauseQualityUpdatesEndTime', 'PauseFeatureUpdatesEndTime') {
        $d = ConvertTo-FWDate (Get-FWValue $Facts.Pause $n)
        if ($d -and $d -gt $Now -and (-not $latest -or $d -gt $latest)) { $latest = $d }
    }
    foreach ($n in 'PauseQualityUpdatesStartTime', 'PauseFeatureUpdatesStartTime') {
        $start = ConvertTo-FWDate (Get-FWValue $Facts.Policy $n)
        if ($start) {
            $end = $start.AddDays(35)   # policy pauses last 35 days from the start date
            if ($end -gt $Now -and (-not $latest -or $end -gt $latest)) { $latest = $end }
        }
    }
    if (-not $latest) { return New-FWCheck 'UpdatePause' 'OK' 'Updates are not paused' }
    $days = [math]::Ceiling(($latest - $Now).TotalDays)
    $status = if ($days -le $Config.thresholds.pauseWarnDays) { 'WARNING' } else { 'ALERT' }
    New-FWCheck 'UpdatePause' $status ("Updates paused until {0:yyyy-MM-dd} ({1} days remaining)" -f $latest, $days)
}

function Test-FWDeferral {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'All checks share one signature (Facts, Config, Now) so Invoke-FWCheck can call them uniformly.')]
    [CmdletBinding()]
    param($Facts, [hashtable]$Config, [datetime]$Now)
    $t = $Config.thresholds
    $q = 0; $f = 0
    if ((Get-FWValue $Facts.Policy 'DeferQualityUpdates') -ne 0) { $q = [int](Get-FWValue $Facts.Policy 'DeferQualityUpdatesPeriodInDays') }
    if ((Get-FWValue $Facts.Policy 'DeferFeatureUpdates') -ne 0) { $f = [int](Get-FWValue $Facts.Policy 'DeferFeatureUpdatesPeriodInDays') }
    $pin = Get-FWValue $Facts.Policy 'TargetReleaseVersionInfo'
    $pinText = if ((Get-FWValue $Facts.Policy 'TargetReleaseVersion') -eq 1 -and $pin) { "; pinned to $pin" } else { '' }
    $detail = "Quality deferral $q days, feature deferral $f days$pinText"
    if ($q -ge $t.qualityDeferralAlertDays) { return New-FWCheck 'Deferral' 'ALERT' $detail }
    if ($q -ge $t.qualityDeferralWarnDays -or $f -ge $t.featureDeferralWarnDays) { return New-FWCheck 'Deferral' 'WARNING' $detail }
    New-FWCheck 'Deferral' 'OK' $detail
}

function Test-FWUpdateSource {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'All checks share one signature (Facts, Config, Now) so Invoke-FWCheck can call them uniformly.')]
    [CmdletBinding()]
    param($Facts, [hashtable]$Config, [datetime]$Now)
    $p = $Facts.Policy
    $useWsus = (Get-FWValue $p 'UseWUServer') -eq 1
    $server = [string](Get-FWValue $p 'WUServer')
    $blockOnline = (Get-FWValue $p 'DoNotConnectToWindowsUpdateInternetLocations') -eq 1
    if ($useWsus -and $server) {
        $approved = @($Config.approvedWsusServers | Where-Object { $server.TrimEnd('/') -ieq "$_".TrimEnd('/') })
        if ($approved.Count) { return New-FWCheck 'UpdateSource' 'OK' "Approved WSUS server $server" }
        return New-FWCheck 'UpdateSource' 'WARNING' "WSUS server $server is not on the approved list"
    }
    if ($blockOnline) { return New-FWCheck 'UpdateSource' 'ALERT' 'Windows Update online is blocked and no WSUS server is configured: no update source' }
    New-FWCheck 'UpdateSource' 'OK' 'Microsoft Windows Update (online)'
}

function Get-FWHistory {
    param($Facts)
    @($Facts.History | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{
                Title = [string]$_.Title; Date = ConvertTo-FWDate $_.Date; ResultCode = [int]$_.ResultCode
                Operation = [int]$_.Operation; HResult = [string]$_.HResult
                Kb = if ("$($_.Title)" -match '(KB\d{6,8})') { $Matches[1] } else { $null }
            }
        } | Where-Object { $_.Date })
}

function Test-FWLastQualityUpdate {
    [CmdletBinding()]
    param($Facts, [hashtable]$Config, [datetime]$Now)
    $t = $Config.thresholds
    if ($Facts.HistorySource -eq 'None') { return New-FWCheck 'LastQualityUpdate' 'WARNING' 'Update history could not be read' }
    $ok = @(Get-FWHistory $Facts | Where-Object {
            $_.Operation -eq 1 -and $_.ResultCode -in 2, 3 -and $_.Title -match $Config.qualityUpdatePattern -and $_.Title -notmatch $Config.qualityUpdateExclude
        } | Sort-Object Date -Descending)
    if (-not $ok.Count) { return New-FWCheck 'LastQualityUpdate' 'WARNING' 'No successful quality update found in the history' }
    $last = $ok[0]
    $days = [int][math]::Floor(($Now - $last.Date).TotalDays)
    $detail = "{0} days ago on {1:yyyy-MM-dd}: {2}" -f $days, $last.Date, $last.Title
    $status = if ($days -gt $t.qualityUpdateAlertDays) { 'ALERT' } elseif ($days -gt $t.qualityUpdateWarnDays) { 'WARNING' } else { 'OK' }
    New-FWCheck 'LastQualityUpdate' $status $detail
}

function Test-FWRecentFailure {
    [CmdletBinding()]
    param($Facts, [hashtable]$Config, [datetime]$Now)
    $t = $Config.thresholds
    $since = $Now.AddDays(-$t.failureLookbackDays)
    $hist = @(Get-FWHistory $Facts | Where-Object { $_.Operation -eq 1 })
    $failed = @($hist | Where-Object { $_.ResultCode -in 4, 5 -and $_.Date -ge $since })
    # A failure counts only if the same update (KB, or title) has not installed successfully since.
    $open = @($failed | Where-Object {
            $f = $_
            -not @($hist | Where-Object {
                    $_.ResultCode -in 2, 3 -and $_.Date -gt $f.Date -and (($f.Kb -and $_.Kb -eq $f.Kb) -or (-not $f.Kb -and $_.Title -eq $f.Title))
                }).Count
        })
    $keys = @($open | ForEach-Object { if ($_.Kb) { "$($_.Kb) ($($_.HResult))" } else { $_.Title } } | Select-Object -Unique)
    if ($keys.Count -ge $t.failureAlertCount) { return New-FWCheck 'RecentFailures' 'ALERT' "$($keys.Count) unresolved failed update(s) in $($t.failureLookbackDays) days: $($keys -join ', ')" }
    if ($keys.Count -ge $t.failureWarnCount -and $keys.Count -gt 0) { return New-FWCheck 'RecentFailures' 'WARNING' "$($keys.Count) unresolved failed update(s) in $($t.failureLookbackDays) days: $($keys -join ', ')" }
    New-FWCheck 'RecentFailures' 'OK' "No unresolved failures in $($t.failureLookbackDays) days"
}

function Test-FWPendingReboot {
    [CmdletBinding()]
    param($Facts, [hashtable]$Config, [datetime]$Now)
    $pending = [bool](Get-FWValue $Facts.Reboot 'WindowsUpdate') -or [bool](Get-FWValue $Facts.Reboot 'ComponentBasedServicing')
    $boot = ConvertTo-FWDate (Get-FWValue $Facts.Os 'LastBootUpTime')
    $uptime = if ($boot) { [int][math]::Floor(($Now - $boot).TotalDays) } else { $null }
    $up = if ($null -ne $uptime) { "; last boot $uptime days ago" } else { '' }
    if (-not $pending) { return New-FWCheck 'PendingReboot' 'OK' "No reboot pending$up" }
    if ($null -ne $uptime -and $uptime -ge $Config.thresholds.rebootAlertDays) { return New-FWCheck 'PendingReboot' 'ALERT' "Reboot pending$up" }
    New-FWCheck 'PendingReboot' 'WARNING' "Reboot pending$up"
}

$script:FWChecks = @(
    'Test-FWUpdateService', 'Test-FWAutomaticUpdate', 'Test-FWUpdatePause', 'Test-FWDeferral',
    'Test-FWUpdateSource', 'Test-FWLastQualityUpdate', 'Test-FWRecentFailure', 'Test-FWPendingReboot'
)

$script:FWCheckNames = @{
    'Test-FWUpdateService' = 'UpdateServices'; 'Test-FWAutomaticUpdate' = 'AutomaticUpdates'; 'Test-FWUpdatePause' = 'UpdatePause'
    'Test-FWDeferral' = 'Deferral'; 'Test-FWUpdateSource' = 'UpdateSource'; 'Test-FWLastQualityUpdate' = 'LastQualityUpdate'
    'Test-FWRecentFailure' = 'RecentFailures'; 'Test-FWPendingReboot' = 'PendingReboot'
}

function Invoke-FWCheck {
    <# Runs every check on one machine's facts. A check that throws becomes a WARNING, never a crash. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Facts, [Parameter(Mandatory)][hashtable]$Config, [datetime]$Now = (Get-Date).ToUniversalTime())
    foreach ($fn in $script:FWChecks) {
        try { & $fn -Facts $Facts -Config $Config -Now $Now }
        catch { New-FWCheck $script:FWCheckNames[$fn] 'WARNING' "Check failed: $($_.Exception.Message)" }
    }
}
