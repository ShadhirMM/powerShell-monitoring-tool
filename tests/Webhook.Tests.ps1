BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\FleetWU\FleetWU.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:config = InModuleScope FleetWU { Get-FWDefaultConfig }
    $script:run = InModuleScope FleetWU -Parameters @{ M = @(New-TestMachines); C = @(New-TestFleetCollection); Cfg = $script:config; Now = (Get-TestNow) } {
        param($M, $C, $Cfg, $Now) New-FWRun -Machines $M -Collections $C -Config $Cfg -Now $Now -StartedAt $Now
    }
    function Get-Payload($Format, $Max = 15, $Run = $script:run) {
        InModuleScope FleetWU -Parameters @{ R = $Run; F = $Format; X = $Max } { param($R, $F, $X) New-FWWebhookPayload -Run $R -Format $F -MaxMachines $X }
    }
    function New-HttpError([int]$Status, [string]$RetryAfter) {
        $ex = [System.Exception]::new("HTTP $Status")
        $headers = @{}
        if ($RetryAfter) { $headers['Retry-After'] = $RetryAfter }
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status; Headers = $headers })
        $ex
    }
}

Describe 'Webhook payloads' {
    It '<_> payload is valid JSON and lists only machines with problems' -ForEach @('teams', 'slack', 'generic') {
        $json = Get-Payload $_ | ConvertTo-Json -Depth 10
        { $json | ConvertFrom-Json } | Should -Not -Throw
        $json | Should -Match 'OFFICE-PC-02'
        $json | Should -Match 'OFFICE-LT-03'
        $json | Should -Not -Match 'OFFICE-PC-01'
        $json | Should -Match '4 machine\(s\): 1 ALERT, 2 WARNING, 1 OK \(1 unreachable\)'
    }

    It 'teams payload is an Adaptive Card with the status colour' {
        $p = Get-Payload 'teams'
        $p.type | Should -Be 'message'
        $p.attachments[0].contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
        $p.attachments[0].content.body[0].color | Should -Be 'Attention'
    }

    It 'generic payload carries counts and findings for automation' {
        $p = Get-Payload 'generic'
        $p.status | Should -Be 'ALERT'
        $p.counts.unreachable | Should -Be 1
        ($p.machines | Where-Object computerName -EQ 'OFFICE-PC-02').findings[0].check | Should -Be 'UpdatePause'
    }

    It 'caps the list and says how many more' {
        $p = Get-Payload 'slack' 1
        $p.text | Should -Match '\.\.\. and 2 more \(see latest.html\)'
    }

    It 'quiet mode: OK runs with nothing resolved are not sent; problems and resolutions are' {
        InModuleScope FleetWU -Parameters @{ R = $script:run; Cfg = $script:config } {
            param($R, $Cfg)
            Test-FWShouldNotify -Run $R -Config $Cfg | Should -BeTrue
            $ok = [pscustomobject]@{ Status = 'OK'; Trend = [pscustomobject]@{ Resolved = @() } }
            Test-FWShouldNotify -Run $ok -Config $Cfg | Should -BeFalse
            $fixed = [pscustomobject]@{ Status = 'OK'; Trend = [pscustomobject]@{ Resolved = @('x') } }
            Test-FWShouldNotify -Run $fixed -Config $Cfg | Should -BeTrue
            $Cfg.webhook.sendWhenOk = $true
            Test-FWShouldNotify -Run $ok -Config $Cfg | Should -BeTrue
        }
    }
}

Describe 'Webhook delivery' {
    It 'sends once on success' {
        InModuleScope FleetWU -Parameters @{ Cfg = $script:config } {
            param($Cfg)
            Mock Invoke-RestMethod { }
            $r = Send-FWWebhook -Url 'https://hooks.example/x' -Payload @{ text = 'hi' } -Webhook $Cfg.webhook -Sleep { }
            $r.Sent | Should -BeTrue
            $r.Attempts | Should -Be 1
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and $ContentType -like 'application/json*' }
        }
    }

    It 'retries 5xx and network errors with the configured delays, then succeeds' {
        InModuleScope FleetWU -Parameters @{ Cfg = $script:config; E503 = (New-HttpError 503) } {
            param($Cfg, $E503)
            $script:calls = 0; $script:waits = @()
            Mock Invoke-RestMethod {
                $script:calls++
                if ($script:calls -eq 1) { throw $E503 }
                if ($script:calls -eq 2) { throw [System.Net.WebException]::new('The remote name could not be resolved') }
            }
            $r = Send-FWWebhook -Url 'https://hooks.example/x' -Payload @{ text = 'hi' } -Webhook $Cfg.webhook -Sleep { param($s) $script:waits += $s }
            $r.Sent | Should -BeTrue
            $r.Attempts | Should -Be 3
            $script:waits | Should -Be @(5, 20)
        }
    }

    It 'honours Retry-After on 429' {
        InModuleScope FleetWU -Parameters @{ Cfg = $script:config; E429 = (New-HttpError 429 '42') } {
            param($Cfg, $E429)
            $script:calls = 0; $script:waits = @()
            Mock Invoke-RestMethod { $script:calls++; if ($script:calls -eq 1) { throw $E429 } }
            $r = Send-FWWebhook -Url 'https://hooks.example/x' -Payload @{ text = 'hi' } -Webhook $Cfg.webhook -Sleep { param($s) $script:waits += $s }
            $r.Sent | Should -BeTrue
            $script:waits | Should -Be @(42)
        }
    }

    It 'does not retry a 4xx, and gives up after the retries on repeated 5xx' {
        InModuleScope FleetWU -Parameters @{ Cfg = $script:config; E404 = (New-HttpError 404); E500 = (New-HttpError 500) } {
            param($Cfg, $E404, $E500)
            Mock Invoke-RestMethod { throw $E404 }
            $r = Send-FWWebhook -Url 'https://hooks.example/x' -Payload @{} -Webhook $Cfg.webhook -Sleep { }
            $r.Sent | Should -BeFalse
            $r.Attempts | Should -Be 1
            $r.Error | Should -Match 'HTTP 404'

            Mock Invoke-RestMethod { throw $E500 }
            $r = Send-FWWebhook -Url 'https://hooks.example/x' -Payload @{} -Webhook $Cfg.webhook -Sleep { }
            $r.Sent | Should -BeFalse
            $r.Attempts | Should -Be 4
        }
    }
}
