BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\FleetWU\FleetWU.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Checks' {
    BeforeAll {
        $script:config = InModuleScope FleetWU { Get-FWDefaultConfig }
        $script:config.approvedWsusServers = @('https://wsus.familyoffice-demo.example:8531')
    }

    It '<Name>: <Check> = <Status>' -ForEach (Get-TestScenario) {
        $result = InModuleScope FleetWU -Parameters @{ Facts = $Facts; Config = $script:config; Now = (Get-TestNow); Check = $Check } {
            param($Facts, $Config, $Now, $Check)
            Invoke-FWCheck -Facts $Facts -Config $Config -Now $Now | Where-Object Check -EQ $Check
        }
        $result.Status | Should -Be $Status
        $result.Detail | Should -Not -BeNullOrEmpty
    }

    It 'a healthy machine passes all 8 checks' {
        $r = InModuleScope FleetWU -Parameters @{ Facts = (New-TestFacts); Config = $script:config; Now = (Get-TestNow) } {
            param($Facts, $Config, $Now) @(Invoke-FWCheck -Facts $Facts -Config $Config -Now $Now)
        }
        $r.Count | Should -Be 8
        @($r | Where-Object Status -NE 'OK').Count | Should -Be 0
    }

    It 'works on deserialized facts (JSON round trip, like remoting)' {
        $facts = New-TestFacts { $f.Policy.NoAutoUpdate = 1; $f.Reboot.WindowsUpdate = $true }
        $roundTrip = $facts | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $r = InModuleScope FleetWU -Parameters @{ Facts = $roundTrip; Config = $script:config; Now = (Get-TestNow) } {
            param($Facts, $Config, $Now) @(Invoke-FWCheck -Facts $Facts -Config $Config -Now $Now)
        }
        ($r | Where-Object Check -EQ 'AutomaticUpdates').Status | Should -Be 'ALERT'
        ($r | Where-Object Check -EQ 'PendingReboot').Status | Should -Be 'WARNING'
        ($r | Where-Object Check -EQ 'LastQualityUpdate').Status | Should -Be 'OK'
    }

    It 'a check that throws becomes a WARNING, never a crash' {
        $r = InModuleScope FleetWU -Parameters @{ Config = $script:config; Now = (Get-TestNow) } {
            param($Config, $Now)
            Mock Test-FWDeferral { throw 'boom' }
            @(Invoke-FWCheck -Facts (New-Object psobject -Property @{ Services = @{ wuauserv = 'Manual'; UsoSvc = 'Auto' }; Policy = @{}; Pause = @{}; Reboot = @{}; Os = @{}; History = @(); HistorySource = 'None'; Errors = @() }) -Config $Config -Now $Now)
        }
        ($r | Where-Object Check -EQ 'Deferral').Status | Should -Be 'WARNING'
        ($r | Where-Object Check -EQ 'Deferral').Detail | Should -Match 'Check failed: boom'
        $r.Count | Should -Be 8
    }

    It 'thresholds come from the config' {
        $facts = New-TestFacts { $f.History = @(New-TestHistory -DaysAgo 40) }
        $strict = InModuleScope FleetWU { Get-FWDefaultConfig }
        $strict.thresholds.qualityUpdateWarnDays = 20
        $strict.thresholds.qualityUpdateAlertDays = 30
        $r = InModuleScope FleetWU -Parameters @{ Facts = $facts; Config = $strict; Now = (Get-TestNow) } {
            param($Facts, $Config, $Now) Test-FWLastQualityUpdate -Facts $Facts -Config $Config -Now $Now
        }
        $r.Status | Should -Be 'ALERT'
    }

    It 'pause detail shows the date and days remaining' {
        $facts = New-TestFacts { $f.Pause.PauseUpdatesExpiryTime = '2026-12-16T09:00:00Z' }
        $r = InModuleScope FleetWU -Parameters @{ Facts = $facts; Config = $script:config; Now = (Get-TestNow) } {
            param($Facts, $Config, $Now) Test-FWUpdatePause -Facts $Facts -Config $Config -Now $Now
        }
        $r.Detail | Should -Be 'Updates paused until 2026-12-16 (22 days remaining)'
    }

    It 'worst status wins' {
        InModuleScope FleetWU {
            Get-FWWorstStatus @('OK', 'WARNING', 'OK') | Should -Be 'WARNING'
            Get-FWWorstStatus @('WARNING', 'ALERT') | Should -Be 'ALERT'
            Get-FWWorstStatus @('OK') | Should -Be 'OK'
        }
    }

    It 'parses registry date formats and rejects junk' {
        InModuleScope FleetWU {
            (ConvertTo-FWDate '2026-12-16T09:00:00Z').ToString('o') | Should -Be '2026-12-16T09:00:00.0000000Z'
            (ConvertTo-FWDate '2026-12-16').Day | Should -Be 16
            ConvertTo-FWDate 'not a date' | Should -BeNullOrEmpty
            ConvertTo-FWDate $null | Should -BeNullOrEmpty
        }
    }
}
