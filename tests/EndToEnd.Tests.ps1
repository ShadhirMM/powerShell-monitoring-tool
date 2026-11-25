BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\FleetWU\FleetWU.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:engine = (Get-Process -Id $PID).Path      # same PowerShell edition as the test run
    $script:inv = Join-Path $TestDrive 'fleet.csv'
    "ComputerName,Group,Tags`nOFFICE-PC-01,Office,desktop`nOFFICE-PC-02,Office,desktop`nRES-MEDIA-01,Residence,media`nOFFICE-LT-03,Office,laptop" | Set-Content $script:inv
}

Describe 'Invoke-FleetWUMonitor (collection mocked with the fictional fleet)' {
    BeforeAll {
        Mock Invoke-FWCollection -ModuleName FleetWU { New-TestFleetCollection }
    }

    It 'writes reports, sends one webhook summary, and shows the trend on the next run' {
        $out = Join-Path $TestDrive 'out1'
        $script:sent = @()
        Mock Invoke-RestMethod -ModuleName FleetWU { $script:sent += [Text.Encoding]::UTF8.GetString($Body) }

        $run1 = Invoke-FleetWUMonitor -InventoryPath $script:inv -OutputDir $out -WebhookUrl 'https://hooks.example/fleet'
        $run1.Status | Should -Be 'ALERT'
        $run1.Webhook.Sent | Should -BeTrue
        $run1.Trend.HasPrevious | Should -BeFalse
        Join-Path $out 'latest.html' | Should -Exist
        $script:sent.Count | Should -Be 1
        $script:sent[0] | Should -Match 'AdaptiveCard'

        Start-Sleep -Seconds 1   # distinct RunId
        $run2 = Invoke-FleetWUMonitor -InventoryPath $script:inv -OutputDir $out -WebhookUrl 'https://hooks.example/fleet'
        $run2.Trend.HasPrevious | Should -BeTrue
        $run2.Trend.PreviousRunId | Should -Be $run1.RunId
        ($run2.Machines | Where-Object ComputerName -EQ 'OFFICE-LT-03').UnreachableRuns | Should -Be 2
        $script:sent.Count | Should -Be 2
        $script:sent[1] | Should -Match 'Since last run: 0 new, 0 worse, 0 resolved'
        @(Get-ChildItem (Join-Path $out 'history') -Filter '*.json').Count | Should -Be 2
    }

    It 'quiet mode: an all-OK fleet sends nothing' {
        Mock Invoke-FWCollection -ModuleName FleetWU { @([pscustomobject]@{ ComputerName = 'OFFICE-PC-01'; Reachability = 'Online'; Facts = (New-TestFacts 'OFFICE-PC-01'); ErrorMessage = $null; Seconds = 1 }) }
        Mock Invoke-RestMethod -ModuleName FleetWU { throw 'must not be called' }
        $inv = Join-Path $TestDrive 'one.csv'; "ComputerName`nOFFICE-PC-01" | Set-Content $inv
        $run = Invoke-FleetWUMonitor -InventoryPath $inv -OutputDir (Join-Path $TestDrive 'out2') -WebhookUrl 'https://hooks.example/fleet'
        $run.Status | Should -Be 'OK'
        $run.Webhook.Skipped | Should -Match 'quiet mode'
        Should -Invoke Invoke-RestMethod -ModuleName FleetWU -Times 0
    }

    It 'no webhook URL: reports are still written and the reason is recorded' {
        $env:FLEETWU_WEBHOOK_URL = $null
        $run = Invoke-FleetWUMonitor -InventoryPath $script:inv -OutputDir (Join-Path $TestDrive 'out3')
        $run.Webhook.Skipped | Should -Match 'FLEETWU_WEBHOOK_URL'
        Join-Path $TestDrive 'out3\latest.csv' | Should -Exist
    }

    It 'a failed webhook does not fail the run' {
        Mock Invoke-RestMethod -ModuleName FleetWU { throw [System.Net.WebException]::new('unreachable') }
        Mock Start-Sleep -ModuleName FleetWU { }
        $run = Invoke-FleetWUMonitor -InventoryPath $script:inv -OutputDir (Join-Path $TestDrive 'out4') -WebhookUrl 'https://hooks.example/fleet' -WarningAction SilentlyContinue
        $run.Webhook.Sent | Should -BeFalse
        $run.Webhook.Attempts | Should -Be 4
        Join-Path $TestDrive 'out4\latest.json' | Should -Exist
    }

    It 'an empty selection is an error, not an empty OK report' {
        { Invoke-FleetWUMonitor -InventoryPath $script:inv -Group Nobody -OutputDir (Join-Path $TestDrive 'out5') } | Should -Throw '*empty*'
    }
}

Describe 'Real run on this machine (Local transport, read-only, no WinRM needed)' {
    It 'checks this computer and produces a full report' {
        $inv = Join-Path $TestDrive 'local.csv'; "ComputerName,Transport`nlocalhost,Local" | Set-Content $inv
        $run = Invoke-FleetWUMonitor -InventoryPath $inv -OutputDir (Join-Path $TestDrive 'real') -NoWebhook
        $run.Machines.Count | Should -Be 1
        $run.Machines[0].Reachability | Should -Be 'Online'
        $run.Status | Should -BeIn @('OK', 'WARNING', 'ALERT')
        @($run.Machines[0].Checks | Where-Object Check -NE 'ProbeError').Count | Should -Be 9
        $run.Machines[0].Os | Should -Match 'build \d+'
    }
}

Describe 'Start-FleetWUMonitor.ps1 exit codes (child process)' {
    It 'exit code matches the status: 0 OK, 1 WARNING, 2 ALERT' {
        $inv = Join-Path $TestDrive 'local2.csv'; "ComputerName,Transport`nlocalhost,Local" | Set-Content $inv
        $out = Join-Path $TestDrive 'exit'
        & $script:engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:root 'src\Start-FleetWUMonitor.ps1') -InventoryPath $inv -OutputDir $out -NoWebhook -Quiet
        $code = $LASTEXITCODE
        $status = (Get-Content (Join-Path $out 'latest.json') -Raw | ConvertFrom-Json).Status
        $code | Should -Be (@{ OK = 0; WARNING = 1; ALERT = 2 }[$status])
        @(Get-Content (Join-Path $out 'fleetwu.log'))[-1] | Should -Match "$status run=\d{8}T\d{6}Z machines=1 .* webhook=skipped: disabled"
    }

    It 'default output folder works when started with powershell -File (PS 5.1 $PSScriptRoot quirk)' {
        $copy = Join-Path $TestDrive 'copy'
        Copy-Item -Path (Join-Path $script:root 'src') -Destination (Join-Path $copy 'src') -Recurse
        $inv = Join-Path $TestDrive 'local3.csv'; "ComputerName,Transport`nlocalhost,Local" | Set-Content $inv
        & $script:engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copy 'src\Start-FleetWUMonitor.ps1') -InventoryPath $inv -NoWebhook -Quiet
        $LASTEXITCODE | Should -BeIn @(0, 1, 2)
        Join-Path $copy 'reports\latest.json' | Should -Exist
    }

    It 'exit code 3 when the run cannot start (bad inventory)' {
        $out = Join-Path $TestDrive 'exit3'
        $ErrorActionPreference = 'Continue'   # the child writes its error to stderr; in PS 5.1 'Stop' would turn that into an exception here
        & $script:engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:root 'src\Start-FleetWUMonitor.ps1') -InventoryPath (Join-Path $TestDrive 'missing.csv') -OutputDir $out -NoWebhook -Quiet 2>$null
        $LASTEXITCODE | Should -Be 3
        @(Get-Content (Join-Path $out 'fleetwu.log'))[-1] | Should -Match 'FAILED Inventory file not found'
    }
}

Describe 'Scheduled task scripts' {
    It 'Register -WhatIf runs the pre-flight and registers nothing' {
        $name = "FleetWU-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $output = & (Join-Path $script:root 'install\Register-FleetWUTask.ps1') -InventoryPath $script:inv -OutputDir (Join-Path $TestDrive 'task') -TaskName $name -WhatIf -WarningAction SilentlyContinue
        ($output -join "`n") | Should -Match 'Pre-flight OK: config valid, 4 machine\(s\)'
        Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Register refuses a bad inventory before touching Task Scheduler' {
        $bad = Join-Path $TestDrive 'dup.csv'; "ComputerName`nPC-A`nPC-A" | Set-Content $bad
        { & (Join-Path $script:root 'install\Register-FleetWUTask.ps1') -InventoryPath $bad -TaskName 'FleetWU-never' -WhatIf } | Should -Throw '*Duplicate*'
    }

    It 'Unregister of a missing task is a no-op' {
        (& (Join-Path $script:root 'install\Unregister-FleetWUTask.ps1') -TaskName 'FleetWU-does-not-exist') | Should -Match 'nothing to do'
    }
}
