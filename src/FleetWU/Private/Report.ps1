function New-FWMachineResult {
    <# Turns one collection result into a machine report: checks, status, connectivity streak. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine,
        [Parameter(Mandatory)]$Collection,
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now,
        $PreviousMachine
    )
    $online = $Collection.Reachability -eq 'Online'
    $streak = 0
    if (-not $online) {
        $streak = 1
        if ($PreviousMachine -and $PreviousMachine.Reachability -ne 'Online') { $streak = [int]$PreviousMachine.UnreachableRuns + 1 }
    }

    $checks = @()
    if ($online) {
        $checks += New-FWCheck 'Connectivity' 'OK' ("Online ({0}s)" -f $Collection.Seconds)
        $checks += @(Invoke-FWCheck -Facts $Collection.Facts -Config $Config -Now $Now)
        foreach ($e in @($Collection.Facts.Errors)) { if ($e) { $checks += New-FWCheck 'ProbeError' 'WARNING' "Partial data: $e" } }
    } else {
        $sev = if ($streak -ge $Config.thresholds.unreachableAlertRuns) { 'ALERT' } else { 'WARNING' }
        $checks += New-FWCheck 'Connectivity' $sev ("{0}: {1} ({2} run(s) in a row)" -f $Collection.Reachability, $Collection.ErrorMessage, $streak)
    }

    $os = $null
    if ($online -and $Collection.Facts.Os) {
        $o = $Collection.Facts.Os
        $build = (Get-FWValue $o 'Build'); $ubr = (Get-FWValue $o 'UBR')
        $os = ('{0} {1} (build {2}{3})' -f (Get-FWValue $o 'Caption'), (Get-FWValue $o 'DisplayVersion'), $build, $(if ($ubr) { ".$ubr" } else { '' })).Trim()
    }
    [pscustomobject]@{
        ComputerName    = $Machine.ComputerName
        Group           = $Machine.Group
        Tags            = @($Machine.Tags)
        Transport       = $Machine.Transport
        Reachability    = $Collection.Reachability
        UnreachableRuns = $streak
        Status          = Get-FWWorstStatus @($checks | ForEach-Object Status)
        Os              = $os
        CollectedAt     = if ($online) { $Collection.Facts.CollectedAt } else { $null }
        Checks          = @($checks)
    }
}

function New-FWRun {
    <# Builds the run object for the whole fleet and the trend against the previous run. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Machines,
        [Parameter(Mandatory)][object[]]$Collections,
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date).ToUniversalTime(),
        [datetime]$StartedAt = $Now,
        $PreviousRun
    )
    $results = foreach ($m in $Machines) {
        $c = $Collections | Where-Object { $_.ComputerName -ieq $m.ComputerName } | Select-Object -First 1
        if (-not $c) { $c = New-FWCollectionResult -ComputerName $m.ComputerName -Reachability 'Error' -ErrorMessage 'No collection result' }
        $prev = $null
        if ($PreviousRun) { $prev = $PreviousRun.Machines | Where-Object { $_.ComputerName -ieq $m.ComputerName } | Select-Object -First 1 }
        New-FWMachineResult -Machine $m -Collection $c -Config $Config -Now $Now -PreviousMachine $prev
    }
    $results = @($results | Sort-Object @{ Expression = { $script:FWStatusRank[$_.Status] }; Descending = $true }, ComputerName)
    $run = [pscustomobject]@{
        RunId       = $StartedAt.ToString('yyyyMMddTHHmmssZ')
        StartedAt   = $StartedAt.ToString('o')
        FinishedAt  = (Get-Date).ToUniversalTime().ToString('o')
        ToolVersion = $script:FWVersion
        Status      = if ($results.Count) { Get-FWWorstStatus @($results | ForEach-Object Status) } else { 'OK' }
        Counts      = [pscustomobject]@{
            Total       = $results.Count
            OK          = @($results | Where-Object Status -EQ 'OK').Count
            WARNING     = @($results | Where-Object Status -EQ 'WARNING').Count
            ALERT       = @($results | Where-Object Status -EQ 'ALERT').Count
            Unreachable = @($results | Where-Object Reachability -NE 'Online').Count
        }
        Machines    = $results
        Trend       = $null
    }
    $run.Trend = Compare-FWRun -Previous $PreviousRun -Current $run
    $run
}

function Compare-FWRun {
    <# New problems, resolved, worsened, still failing; machines added/removed. #>
    [CmdletBinding()]
    param($Previous, [Parameter(Mandatory)]$Current)
    $empty = [pscustomobject]@{ HasPrevious = $false; PreviousRunId = $null; New = @(); Resolved = @(); Worsened = @(); Persisting = @(); AddedMachines = @(); RemovedMachines = @() }
    if (-not $Previous) { return $empty }

    $index = {
        param($run)
        $h = @{}
        foreach ($m in $run.Machines) { foreach ($c in $m.Checks) { $h["$($m.ComputerName.ToLowerInvariant())|$($c.Check)"] = [pscustomobject]@{ ComputerName = $m.ComputerName; Check = $c.Check; Status = $c.Status; Detail = $c.Detail } } }
        $h
    }
    $prev = & $index $Previous
    $cur = & $index $Current
    $new = @(); $resolved = @(); $worse = @(); $persist = @()
    foreach ($k in $cur.Keys) {
        $c = $cur[$k]; $p = $prev[$k]
        $pStatus = if ($p) { $p.Status } else { 'OK' }
        $item = [pscustomobject]@{ ComputerName = $c.ComputerName; Check = $c.Check; Previous = $pStatus; Current = $c.Status; Detail = $c.Detail }
        if ($c.Status -ne 'OK' -and $pStatus -eq 'OK') { $new += $item }
        elseif ($c.Status -eq 'ALERT' -and $pStatus -eq 'WARNING') { $worse += $item }
        elseif ($c.Status -ne 'OK') { $persist += $item }
    }
    foreach ($k in $prev.Keys) {
        $p = $prev[$k]
        if ($p.Status -eq 'OK') { continue }
        $c = $cur[$k]
        $machineStillThere = @($Current.Machines | Where-Object { $_.ComputerName -ieq $p.ComputerName }).Count -gt 0
        if ($machineStillThere -and (-not $c -or $c.Status -eq 'OK')) {
            $resolved += [pscustomobject]@{ ComputerName = $p.ComputerName; Check = $p.Check; Previous = $p.Status; Current = 'OK'; Detail = if ($c) { $c.Detail } else { 'No longer reported' } }
        }
    }
    $prevNames = @($Previous.Machines | ForEach-Object { $_.ComputerName.ToLowerInvariant() })
    $curNames = @($Current.Machines | ForEach-Object { $_.ComputerName.ToLowerInvariant() })
    [pscustomobject]@{
        HasPrevious     = $true
        PreviousRunId   = $Previous.RunId
        New             = $new
        Resolved        = $resolved
        Worsened        = $worse
        Persisting      = $persist
        AddedMachines   = @($Current.Machines | Where-Object { $prevNames -notcontains $_.ComputerName.ToLowerInvariant() } | ForEach-Object ComputerName)
        RemovedMachines = @($Previous.Machines | Where-Object { $curNames -notcontains $_.ComputerName.ToLowerInvariant() } | ForEach-Object ComputerName)
    }
}

function ConvertTo-FWCsvRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run)
    foreach ($m in $Run.Machines) {
        foreach ($c in $m.Checks) {
            [pscustomobject]@{
                RunId = $Run.RunId; ComputerName = $m.ComputerName; Group = $m.Group; MachineStatus = $m.Status
                Reachability = $m.Reachability; Check = $c.Check; CheckStatus = $c.Status; Detail = $c.Detail; Os = $m.Os
            }
        }
    }
}

function Get-FWPreviousRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HistoryDir)
    if (-not (Test-Path -LiteralPath $HistoryDir)) { return $null }
    $last = Get-ChildItem -LiteralPath $HistoryDir -Filter 'run-*.json' | Sort-Object Name | Select-Object -Last 1
    if (-not $last) { return $null }
    try { Get-Content -LiteralPath $last.FullName -Raw | ConvertFrom-Json }
    catch { Write-Warning "Previous run $($last.Name) is unreadable; trend skipped. $($_.Exception.Message)"; $null }
}

function Save-FWRun {
    <#
    .SYNOPSIS
        Writes latest.json / latest.csv / latest.html, the run's history files, and prunes old runs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$OutputDir, [int]$KeepRuns = 26)
    $history = Join-Path $OutputDir 'history'
    $null = New-Item -ItemType Directory -Path $history -Force
    $json = $Run | ConvertTo-Json -Depth 8
    $csv = @(ConvertTo-FWCsvRow -Run $Run)
    $html = ConvertTo-FWHtml -Run $Run

    $files = @{
        Json = Join-Path $history "run-$($Run.RunId).json"
        Html = Join-Path $history "run-$($Run.RunId).html"
        Csv  = Join-Path $history "run-$($Run.RunId).csv"
    }
    [IO.File]::WriteAllText($files.Json, $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($files.Html, $html, [Text.UTF8Encoding]::new($false))
    $csv | Export-Csv -LiteralPath $files.Csv -NoTypeInformation -Encoding UTF8
    Copy-Item -LiteralPath $files.Json -Destination (Join-Path $OutputDir 'latest.json') -Force
    Copy-Item -LiteralPath $files.Html -Destination (Join-Path $OutputDir 'latest.html') -Force
    Copy-Item -LiteralPath $files.Csv -Destination (Join-Path $OutputDir 'latest.csv') -Force

    # Retention: keep the newest $KeepRuns runs (all three files of a run go together).
    $runs = @(Get-ChildItem -LiteralPath $history -Filter 'run-*.json' | Sort-Object Name)
    $pruned = @()
    if ($runs.Count -gt $KeepRuns) {
        foreach ($old in $runs[0..($runs.Count - $KeepRuns - 1)]) {
            $base = [IO.Path]::GetFileNameWithoutExtension($old.Name)
            Get-ChildItem -LiteralPath $history -Filter "$base.*" | Remove-Item -Force
            $pruned += $base
        }
    }
    [pscustomobject]@{ Json = $files.Json; Html = $files.Html; Csv = $files.Csv; Pruned = $pruned }
}
