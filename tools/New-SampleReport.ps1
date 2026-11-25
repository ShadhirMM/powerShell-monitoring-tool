<#
.SYNOPSIS
    Builds the sample reports in docs/samples from the fictional test fleet (two runs, so the trend shows).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'src\FleetWU\FleetWU.psd1') -Force
. (Join-Path $root 'tests\TestHelpers.ps1')
$out = Join-Path $root 'docs\samples'

$samples = InModuleScope FleetWU -Parameters @{ Now = (Get-TestNow) } {
    param($Now)
    $cfg = Get-FWDefaultConfig
    $machines = @(New-TestMachines 'OFFICE-PC-01', 'OFFICE-PC-02', 'RES-MEDIA-01', 'OFFICE-LT-03', 'RES-KIOSK-04')
    $week1 = @(New-TestFleetCollection) + [pscustomobject]@{ ComputerName = 'RES-KIOSK-04'; Reachability = 'Online'; Facts = (New-TestFacts 'RES-KIOSK-04' { $f.Policy.AUOptions = 3 }); ErrorMessage = $null; Seconds = 1.8 }
    $prev = New-FWRun -Machines $machines -Collections $week1 -Config $cfg -Now $Now.AddDays(-7) -StartedAt $Now.AddDays(-7)
    $prev = $prev | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $week2 = @(
        [pscustomobject]@{ ComputerName = 'OFFICE-PC-01'; Reachability = 'Online'; Facts = (New-TestFacts 'OFFICE-PC-01' { $f.Policy.NoAutoUpdate = 1 }); ErrorMessage = $null; Seconds = 2.2 }
        [pscustomobject]@{ ComputerName = 'OFFICE-PC-02'; Reachability = 'Online'; Facts = (New-TestFacts 'OFFICE-PC-02' { $f.Pause.PauseUpdatesExpiryTime = (Get-TestNow).AddDays(14).ToString('yyyy-MM-ddTHH:mm:ssZ'); $f.History = @(New-TestHistory -DaysAgo 47 -Title '2026-10 Cumulative Update for Windows 11 (KB5098001)') }); ErrorMessage = $null; Seconds = 2.6 }
        [pscustomobject]@{ ComputerName = 'RES-MEDIA-01'; Reachability = 'Online'; Facts = (New-TestFacts 'RES-MEDIA-01' { $f.Reboot.WindowsUpdate = $true; $f.Os.LastBootUpTime = (Get-TestNow).AddDays(-9).ToString('o') }); ErrorMessage = $null; Seconds = 3.1 }
        [pscustomobject]@{ ComputerName = 'OFFICE-LT-03'; Reachability = 'Unreachable'; Facts = $null; ErrorMessage = 'WinRM cannot complete the operation.'; Seconds = 15.0 }
        [pscustomobject]@{ ComputerName = 'RES-KIOSK-04'; Reachability = 'Online'; Facts = (New-TestFacts 'RES-KIOSK-04'); ErrorMessage = $null; Seconds = 1.7 }
    )
    $run = New-FWRun -Machines $machines -Collections $week2 -Config $cfg -Now $Now -StartedAt $Now -PreviousRun $prev
    $run.FinishedAt = $Now.AddSeconds(19).ToString('o')
    @{
        Run     = $run
        Html    = ConvertTo-FWHtml -Run $run
        Csv     = @(ConvertTo-FWCsvRow -Run $run)
        Teams   = New-FWWebhookPayload -Run $run -Format teams
        Slack   = New-FWWebhookPayload -Run $run -Format slack
        Generic = New-FWWebhookPayload -Run $run -Format generic
    }
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $out 'report.html'), $samples.Html, $utf8)
[IO.File]::WriteAllText((Join-Path $out 'report.json'), ($samples.Run | ConvertTo-Json -Depth 8), $utf8)
$samples.Csv | Export-Csv (Join-Path $out 'report.csv') -NoTypeInformation -Encoding UTF8
foreach ($f in 'Teams', 'Slack', 'Generic') { [IO.File]::WriteAllText((Join-Path $out "payload-$($f.ToLower()).json"), ($samples[$f] | ConvertTo-Json -Depth 10), $utf8) }
[IO.File]::WriteAllText((Join-Path $out 'console.txt'), (Format-FWConsoleReport -Run $samples.Run) + "`n", $utf8)
Write-Output "Samples written to $out"
