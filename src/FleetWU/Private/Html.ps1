function ConvertTo-FWHtml {
    <# Self-contained HTML dashboard (inline CSS, no scripts, no external resources). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Run)
    $e = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $badge = { param($s) "<span class=`"b $(($s).ToLowerInvariant())`">$(& $e $s)</span>" }
    $sb = New-Object System.Text.StringBuilder
    $add = { param($s) [void]$sb.AppendLine($s) }

    & $add '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
    & $add "<title>Windows Update fleet report $(& $e $Run.RunId)</title><style>"
    & $add 'body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1f2328;background:#f6f8fa}h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px}'
    & $add '.meta{color:#57606a;font-size:13px}.tiles{display:flex;gap:12px;margin:16px 0;flex-wrap:wrap}.tile{background:#fff;border:1px solid #d0d7de;border-radius:8px;padding:12px 18px;min-width:110px}'
    & $add '.tile .n{font-size:26px;font-weight:600}.tile .l{font-size:12px;color:#57606a;text-transform:uppercase}table{border-collapse:collapse;width:100%;background:#fff;font-size:13px}'
    & $add 'th,td{border:1px solid #d0d7de;padding:6px 8px;text-align:left;vertical-align:top}th{background:#eaeef2}.b{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;color:#fff}'
    & $add '.ok{background:#1a7f37}.warning{background:#9a6700}.alert{background:#cf222e}details summary{cursor:pointer}.muted{color:#57606a}ul{margin:4px 0 0 18px;padding:0}'
    & $add '</style></head><body>'
    & $add "<h1>Windows Update fleet report $(& $badge $Run.Status)</h1>"
    & $add "<div class=`"meta`">Run $(& $e $Run.RunId) &middot; started $(& $e $Run.StartedAt) UTC &middot; FleetWU $(& $e $Run.ToolVersion) &middot; read-only check, no settings changed</div>"
    & $add '<div class="tiles">'
    foreach ($t in @(@('Machines', $Run.Counts.Total), @('OK', $Run.Counts.OK), @('Warning', $Run.Counts.WARNING), @('Alert', $Run.Counts.ALERT), @('Unreachable', $Run.Counts.Unreachable))) {
        & $add "<div class=`"tile`"><div class=`"n`">$($t[1])</div><div class=`"l`">$($t[0])</div></div>"
    }
    & $add '</div>'

    & $add '<h2>Changes since the previous run</h2>'
    $tr = $Run.Trend
    if (-not $tr -or -not $tr.HasPrevious) {
        & $add '<p class="muted">First run: no previous run to compare with.</p>'
    } else {
        & $add "<p class=`"muted`">Compared with run $(& $e $tr.PreviousRunId).</p><table><tr><th>Change</th><th>Machine</th><th>Check</th><th>Was</th><th>Now</th><th>Detail</th></tr>"
        $rows = @()
        foreach ($i in @($tr.New)) { $rows += , @('New problem', $i) }
        foreach ($i in @($tr.Worsened)) { $rows += , @('Worse', $i) }
        foreach ($i in @($tr.Resolved)) { $rows += , @('Resolved', $i) }
        foreach ($r in $rows) {
            $i = $r[1]
            & $add "<tr><td>$($r[0])</td><td>$(& $e $i.ComputerName)</td><td>$(& $e $i.Check)</td><td>$(& $badge $i.Previous)</td><td>$(& $badge $i.Current)</td><td>$(& $e $i.Detail)</td></tr>"
        }
        if (-not $rows.Count) { & $add '<tr><td colspan="6" class="muted">No changes.</td></tr>' }
        & $add '</table>'
        $still = @($tr.Persisting).Count
        & $add "<p class=`"muted`">Still failing from before: $still check(s). Added machines: $(& $e (@($tr.AddedMachines) -join ', ')). Removed machines: $(& $e (@($tr.RemovedMachines) -join ', ')).</p>"
    }

    & $add '<h2>Machines</h2><table><tr><th>Status</th><th>Machine</th><th>Group</th><th>Operating system</th><th>Findings</th></tr>'
    foreach ($m in $Run.Machines) {
        $problems = @($m.Checks | Where-Object Status -NE 'OK')
        $findings = if ($problems.Count) {
            '<ul>' + (($problems | ForEach-Object { "<li>$(& $badge $_.Status) <b>$(& $e $_.Check)</b>: $(& $e $_.Detail)</li>" }) -join '') + '</ul>'
        } else { '<span class="muted">All checks OK</span>' }
        $all = '<details><summary>All checks</summary><ul>' + (($m.Checks | ForEach-Object { "<li>$(& $badge $_.Status) $(& $e $_.Check): $(& $e $_.Detail)</li>" }) -join '') + '</ul></details>'
        & $add "<tr><td>$(& $badge $m.Status)</td><td>$(& $e $m.ComputerName)</td><td>$(& $e $m.Group)</td><td>$(& $e $m.Os)</td><td>$findings$all</td></tr>"
    }
    & $add '</table></body></html>'
    $sb.ToString()
}
