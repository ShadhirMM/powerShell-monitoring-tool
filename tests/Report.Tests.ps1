BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\FleetWU\FleetWU.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:config = InModuleScope FleetWU { Get-FWDefaultConfig }

    function New-Run($Collections, $Previous, $Machines = (New-TestMachines)) {
        InModuleScope FleetWU -Parameters @{ M = @($Machines); C = @($Collections); P = $Previous; Cfg = $script:config; Now = (Get-TestNow) } {
            param($M, $C, $P, $Cfg, $Now) New-FWRun -Machines $M -Collections $C -Config $Cfg -Now $Now -StartedAt $Now -PreviousRun $P
        }
    }
    function Round-Trip($Run) { $Run | ConvertTo-Json -Depth 8 | ConvertFrom-Json }
}

Describe 'Fleet run' {
    It 'summarises the fleet: counts, worst status, problem machines first' {
        $run = New-Run (New-TestFleetCollection) $null
        $run.Status | Should -Be 'ALERT'
        $run.Counts.Total | Should -Be 4
        $run.Counts.ALERT | Should -Be 1
        $run.Counts.WARNING | Should -Be 2
        $run.Counts.OK | Should -Be 1
        $run.Counts.Unreachable | Should -Be 1
        $run.Machines[0].ComputerName | Should -Be 'OFFICE-PC-02'
        $run.Machines[-1].ComputerName | Should -Be 'OFFICE-PC-01'
        $run.RunId | Should -Be '20261125T060000Z'
    }

    It 'online machines get 9 checks (connectivity + 8); unreachable ones get one' {
        $run = New-Run (New-TestFleetCollection) $null
        (($run.Machines | Where-Object ComputerName -EQ 'OFFICE-PC-01').Checks).Count | Should -Be 9
        $lt = $run.Machines | Where-Object ComputerName -EQ 'OFFICE-LT-03'
        $lt.Checks.Count | Should -Be 1
        $lt.Status | Should -Be 'WARNING'
        $lt.Checks[0].Detail | Should -Match 'Unreachable: WinRM cannot complete the operation. \(1 run\(s\) in a row\)'
    }

    It 'an unreachable machine escalates to ALERT after 3 runs in a row and resets when back' {
        $r1 = Round-Trip (New-Run (New-TestFleetCollection) $null)
        $r2 = Round-Trip (New-Run (New-TestFleetCollection) $r1)
        $r3 = New-Run (New-TestFleetCollection) $r2
        ($r2.Machines | Where-Object ComputerName -EQ 'OFFICE-LT-03').UnreachableRuns | Should -Be 2
        $lt = $r3.Machines | Where-Object ComputerName -EQ 'OFFICE-LT-03'
        $lt.UnreachableRuns | Should -Be 3
        $lt.Status | Should -Be 'ALERT'
        $back = New-TestFleetCollection
        $back[3] = [pscustomobject]@{ ComputerName = 'OFFICE-LT-03'; Reachability = 'Online'; Facts = (New-TestFacts 'OFFICE-LT-03'); ErrorMessage = $null; Seconds = 1 }
        $r4 = New-Run $back (Round-Trip $r3)
        ($r4.Machines | Where-Object ComputerName -EQ 'OFFICE-LT-03').UnreachableRuns | Should -Be 0
    }

    It 'probe partial errors are reported as a WARNING finding' {
        $c = @([pscustomobject]@{ ComputerName = 'OFFICE-PC-01'; Reachability = 'Online'; Facts = (New-TestFacts { $f.Errors = @('Policy: Access is denied') }); ErrorMessage = $null; Seconds = 1 })
        $run = New-Run $c $null (New-TestMachines 'OFFICE-PC-01')
        ($run.Machines[0].Checks | Where-Object Check -EQ 'ProbeError').Detail | Should -Be 'Partial data: Policy: Access is denied'
        $run.Status | Should -Be 'WARNING'
    }
}

Describe 'Trend' {
    It 'first run has no comparison' {
        $run = New-Run (New-TestFleetCollection) $null
        $run.Trend.HasPrevious | Should -BeFalse
    }

    It 'finds new, worse, resolved and still-failing problems, added and removed machines' {
        $before = New-TestFleetCollection
        $prev = Round-Trip (New-Run $before $null)
        $after = @(
            [pscustomobject]@{ ComputerName = 'OFFICE-PC-01'; Reachability = 'Online'; Facts = (New-TestFacts 'OFFICE-PC-01' { $f.Policy.NoAutoUpdate = 1 }); ErrorMessage = $null; Seconds = 1 }   # new problem
            [pscustomobject]@{ ComputerName = 'OFFICE-PC-02'; Reachability = 'Online'; Facts = (New-TestFacts 'OFFICE-PC-02'); ErrorMessage = $null; Seconds = 1 }                                # pause resolved
            [pscustomobject]@{ ComputerName = 'RES-MEDIA-01'; Reachability = 'Online'; Facts = (New-TestFacts 'RES-MEDIA-01' { $f.Reboot.WindowsUpdate = $true; $f.Os.LastBootUpTime = (Get-TestNow).AddDays(-10).ToString('o') }); ErrorMessage = $null; Seconds = 1 }  # reboot worse
            [pscustomobject]@{ ComputerName = 'NEW-PC-09'; Reachability = 'Online'; Facts = (New-TestFacts 'NEW-PC-09'); ErrorMessage = $null; Seconds = 1 }
        )
        $run = New-Run $after $prev (New-TestMachines 'OFFICE-PC-01', 'OFFICE-PC-02', 'RES-MEDIA-01', 'NEW-PC-09')
        $t = $run.Trend
        $t.HasPrevious | Should -BeTrue
        $t.PreviousRunId | Should -Be '20261125T060000Z'
        ($t.New | ForEach-Object { "$($_.ComputerName)/$($_.Check)" }) | Should -Be @('OFFICE-PC-01/AutomaticUpdates')
        ($t.Worsened | ForEach-Object { "$($_.ComputerName)/$($_.Check)" }) | Should -Be @('RES-MEDIA-01/PendingReboot')
        ($t.Resolved | ForEach-Object { "$($_.ComputerName)/$($_.Check)" }) | Should -Be @('OFFICE-PC-02/UpdatePause')
        $t.AddedMachines | Should -Be @('NEW-PC-09')
        $t.RemovedMachines | Should -Be @('OFFICE-LT-03')
    }

    It 'an unchanged problem is "still failing", not new' {
        $prev = Round-Trip (New-Run (New-TestFleetCollection) $null)
        $run = New-Run (New-TestFleetCollection) $prev
        @($run.Trend.New).Count | Should -Be 0
        @($run.Trend.Resolved).Count | Should -Be 0
        (@($run.Trend.Persisting) | ForEach-Object { "$($_.ComputerName)/$($_.Check)" }) | Should -Contain 'OFFICE-PC-02/UpdatePause'
    }
}

Describe 'Files, retention and HTML' {
    It 'writes latest + history files and keeps only the newest runs' {
        $out = Join-Path $TestDrive 'out'
        $base = New-Run (New-TestFleetCollection) $null
        $files = $null
        foreach ($i in 1..4) {
            $copy = Round-Trip $base
            $copy.RunId = "2026112${i}T060000Z"
            $files = InModuleScope FleetWU -Parameters @{ R = $copy; O = $out } { param($R, $O) Save-FWRun -Run $R -OutputDir $O -KeepRuns 2 }
        }
        @(Get-ChildItem (Join-Path $out 'history') -Filter 'run-*.json').Name | Should -Be @('run-20261123T060000Z.json', 'run-20261124T060000Z.json')
        @(Get-ChildItem (Join-Path $out 'history')).Count | Should -Be 6
        $files.Pruned | Should -Be @('run-20261122T060000Z')
        foreach ($f in 'latest.json', 'latest.csv', 'latest.html') { Join-Path $out $f | Should -Exist }
        $csv = Import-Csv (Join-Path $out 'latest.csv')
        $csv.Count | Should -Be 28    # 3 online x 9 checks + 1 unreachable
        ($csv | Where-Object { $_.ComputerName -eq 'OFFICE-PC-02' -and $_.Check -eq 'UpdatePause' }).CheckStatus | Should -Be 'ALERT'
        $prev = InModuleScope FleetWU -Parameters @{ O = $out } { param($O) Get-FWPreviousRun -HistoryDir (Join-Path $O 'history') }
        $prev.RunId | Should -Be '20261124T060000Z'
    }

    It 'an unreadable previous run is skipped with a warning' {
        $h = Join-Path $TestDrive 'h'; New-Item -ItemType Directory $h | Out-Null
        'not json' | Set-Content (Join-Path $h 'run-20260101T000000Z.json')
        $r = InModuleScope FleetWU -Parameters @{ H = $h } { param($H) Get-FWPreviousRun -HistoryDir $H -WarningAction SilentlyContinue }
        $r | Should -BeNullOrEmpty
    }

    It 'HTML is self-contained, colour-coded and escapes machine data' {
        $c = New-TestFleetCollection
        $c[0].Facts.Policy.WUServer = '<script>alert(1)</script>'
        $c[0].Facts.Policy.UseWUServer = 1
        $prev = Round-Trip (New-Run (New-TestFleetCollection) $null)
        $run = New-Run $c $prev
        $html = InModuleScope FleetWU -Parameters @{ R = $run } { param($R) ConvertTo-FWHtml -Run $R }
        $html | Should -Match '^<!DOCTYPE html>'
        $html | Should -Not -Match '<script'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $html | Should -Not -Match '(src|href)="https?://'
        $html | Should -Match 'class="b alert">ALERT'
        $html | Should -Match 'Changes since the previous run'
        $html | Should -Match 'New problem</td><td>OFFICE-PC-01</td><td>UpdateSource'
    }
}
