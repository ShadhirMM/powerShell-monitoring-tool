function Get-FWDefaultConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    @{
        thresholds = @{
            qualityUpdateWarnDays    = 35
            qualityUpdateAlertDays   = 60
            pauseWarnDays            = 7      # paused this many days or fewer = WARNING, longer = ALERT
            qualityDeferralWarnDays  = 8
            qualityDeferralAlertDays = 15
            featureDeferralWarnDays  = 181
            failureLookbackDays      = 30
            failureWarnCount         = 1
            failureAlertCount        = 3
            rebootAlertDays          = 7
            unreachableAlertRuns     = 3      # unreachable this many runs in a row = ALERT (else WARNING)
        }
        approvedWsusServers     = @()
        qualityUpdatePattern    = '(Cumulative Update|Security Update|Security Monthly Quality Rollup|Quality Update)'
        qualityUpdateExclude    = '(Preview|Defender|Security Intelligence|Malicious Software|\.NET Framework)'
        remote = @{
            throttleLimit     = 16
            openTimeoutSec    = 15
            operationTimeoutSec = 120
            totalTimeoutSec   = 600
            credentialPath    = ''            # optional Export-Clixml file (DPAPI, only readable by the same user on the same machine)
            useSsl            = $false
        }
        report = @{
            keepRuns = 26
        }
        webhook = @{
            format       = 'teams'           # teams | slack | generic
            urlEnvVar    = 'FLEETWU_WEBHOOK_URL'
            sendWhenOk   = $false            # quiet mode: no message when everything is OK and nothing changed
            maxMachines  = 15                # machines listed in the message
            retries      = 3
            retryDelaySec = @(5, 20, 60)
            timeoutSec   = 30
        }
    }
}

function Merge-FWHashtable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Base, [hashtable]$Override)
    $result = @{}
    foreach ($k in $Base.Keys) { $result[$k] = $Base[$k] }
    foreach ($k in $Override.Keys) {
        if ($result[$k] -is [hashtable] -and $Override[$k] -is [hashtable]) {
            $result[$k] = Merge-FWHashtable -Base $result[$k] -Override $Override[$k]
        } else {
            $result[$k] = $Override[$k]
        }
    }
    $result
}

function ConvertTo-FWHashtable {
    # ConvertFrom-Json gives PSCustomObject on PS 5.1 (no -AsHashtable); convert recursively.
    [CmdletBinding()]
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-FWHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-FWHashtable $_ })
    }
    $InputObject
}

function Test-FWConfig {
    <# Returns a list of problems; empty = valid. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([hashtable]$Config)
    $p = New-Object System.Collections.Generic.List[string]
    $t = $Config.thresholds
    foreach ($k in $t.Keys) {
        if (-not ($t[$k] -is [int] -or $t[$k] -is [long] -or $t[$k] -is [double]) -or $t[$k] -lt 0) { $p.Add("thresholds.$k must be a non-negative number") }
    }
    if ($p.Count -eq 0) {
        if ($t.qualityUpdateWarnDays -ge $t.qualityUpdateAlertDays) { $p.Add('thresholds.qualityUpdateWarnDays must be lower than qualityUpdateAlertDays') }
        if ($t.qualityDeferralWarnDays -ge $t.qualityDeferralAlertDays) { $p.Add('thresholds.qualityDeferralWarnDays must be lower than qualityDeferralAlertDays') }
        if ($t.failureWarnCount -gt $t.failureAlertCount) { $p.Add('thresholds.failureWarnCount must not exceed failureAlertCount') }
        if ($t.unreachableAlertRuns -lt 1) { $p.Add('thresholds.unreachableAlertRuns must be at least 1') }
    }
    if ($Config.webhook.format -notin 'teams', 'slack', 'generic') { $p.Add("webhook.format must be teams, slack or generic (got '$($Config.webhook.format)')") }
    if (@($Config.webhook.retryDelaySec).Count -lt $Config.webhook.retries) { $p.Add('webhook.retryDelaySec needs one value per retry') }
    if ($Config.remote.throttleLimit -lt 1 -or $Config.remote.throttleLimit -gt 64) { $p.Add('remote.throttleLimit must be 1-64') }
    if ($Config.report.keepRuns -lt 2) { $p.Add('report.keepRuns must be at least 2 (trend needs the previous run)') }
    foreach ($rx in 'qualityUpdatePattern', 'qualityUpdateExclude') {
        try { [void][regex]::new($Config[$rx]) } catch { $p.Add("$rx is not a valid regular expression") }
    }
    , $p.ToArray()
}

function Get-FWConfig {
    <# Defaults merged with an optional JSON file. Throws on invalid values. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path)
    $config = Get-FWDefaultConfig
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
        try { $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
        catch { throw "Config file is not valid JSON: $Path ($($_.Exception.Message))" }
        $config = Merge-FWHashtable -Base $config -Override (ConvertTo-FWHashtable $json)
    }
    $problems = Test-FWConfig -Config $config
    if ($problems.Count) { throw "Invalid configuration: $($problems -join '; ')" }
    $config
}
