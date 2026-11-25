BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\FleetWU\FleetWU.psd1') -Force
    $script:root = Join-Path $PSScriptRoot '..'
}

Describe 'Configuration' {
    It 'defaults and the shipped config file are valid' {
        Test-FWConfig -Config (InModuleScope FleetWU { Get-FWDefaultConfig }) | Should -BeNullOrEmpty
        $c = Get-FWConfig -Path (Join-Path $script:root 'config\fleetwu.config.json')
        $c.thresholds.qualityUpdateAlertDays | Should -Be 60
        $c.approvedWsusServers | Should -Contain 'https://wsus.familyoffice-demo.example:8531'
    }

    It 'a partial file overrides only what it sets' {
        $p = Join-Path $TestDrive 'partial.json'
        '{ "thresholds": { "rebootAlertDays": 3 }, "webhook": { "format": "slack" } }' | Set-Content $p
        $c = Get-FWConfig -Path $p
        $c.thresholds.rebootAlertDays | Should -Be 3
        $c.thresholds.qualityUpdateWarnDays | Should -Be 35
        $c.webhook.format | Should -Be 'slack'
        $c.webhook.retries | Should -Be 3
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'warn >= alert'; Json = '{ "thresholds": { "qualityUpdateWarnDays": 90 } }'; Match = 'qualityUpdateWarnDays' }
        @{ Case = 'negative threshold'; Json = '{ "thresholds": { "rebootAlertDays": -1 } }'; Match = 'non-negative' }
        @{ Case = 'unknown webhook format'; Json = '{ "webhook": { "format": "email" } }'; Match = 'teams, slack or generic' }
        @{ Case = 'throttle out of range'; Json = '{ "remote": { "throttleLimit": 500 } }'; Match = 'throttleLimit' }
        @{ Case = 'too few retry delays'; Json = '{ "webhook": { "retries": 5 } }'; Match = 'retryDelaySec' }
        @{ Case = 'bad regex'; Json = '{ "qualityUpdatePattern": "([" }'; Match = 'regular expression' }
        @{ Case = 'keepRuns 1'; Json = '{ "report": { "keepRuns": 1 } }'; Match = 'keepRuns' }
    ) {
        $p = Join-Path $TestDrive 'bad.json'
        $Json | Set-Content $p
        { Get-FWConfig -Path $p } | Should -Throw "*$Match*"
    }

    It 'reports a missing file and invalid JSON clearly' {
        { Get-FWConfig -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
        $p = Join-Path $TestDrive 'broken.json'
        '{ "thresholds": ' | Set-Content $p
        { Get-FWConfig -Path $p } | Should -Throw '*not valid JSON*'
    }
}

Describe 'Inventory' {
    It 'loads the example CSV: disabled rows dropped, local machine detected, tags split' {
        $m = Import-FWInventory -Path (Join-Path $script:root 'config\inventory.example.csv')
        $m.Count | Should -Be 5
        ($m | Where-Object ComputerName -EQ 'localhost').Transport | Should -Be 'Local'
        ($m | Where-Object ComputerName -EQ 'OFFICE-LT-03').Tags | Should -Be @('laptop', 'travel')
        $m.ComputerName | Should -Not -Contain 'RES-KIOSK-02'
    }

    It 'filters by group and tag' {
        $p = Join-Path $script:root 'config\inventory.example.csv'
        (Import-FWInventory -Path $p -Group Residence).ComputerName | Should -Be @('RES-MEDIA-01')
        (Import-FWInventory -Path $p -Tag always-on).Count | Should -Be 2
        (Import-FWInventory -Path $p -Group Nobody).Count | Should -Be 0
    }

    It 'loads JSON with array tags and fills defaults for missing columns' {
        $p = Join-Path $TestDrive 'inv.json'
        '[{ "ComputerName": "SRV-01", "Tags": ["server","dc"] }, { "ComputerName": "localhost" }]' | Set-Content $p
        $m = Import-FWInventory -Path $p
        $m[0].Group | Should -Be 'Default'
        $m[0].Transport | Should -Be 'Remote'
        $m[0].Tags | Should -Be @('server', 'dc')
        $m[1].Transport | Should -Be 'Local'
    }

    It 'a minimal CSV with only ComputerName works' {
        $p = Join-Path $TestDrive 'min.csv'
        "ComputerName`nPC-A`nPC-B" | Set-Content $p
        (Import-FWInventory -Path $p).Count | Should -Be 2
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'duplicates (any case)'; Csv = "ComputerName`nPC-A`npc-a"; Match = 'Duplicate' }
        @{ Case = 'empty name'; Csv = "ComputerName,Group`n,Office"; Match = 'without ComputerName' }
        @{ Case = 'unsafe name'; Csv = "ComputerName`nPC;rm"; Match = 'Invalid ComputerName' }
        @{ Case = 'unknown transport'; Csv = "ComputerName,Transport`nPC-A,Ssh"; Match = 'Invalid Transport' }
    ) {
        $p = Join-Path $TestDrive 'bad.csv'
        $Csv | Set-Content $p
        { Import-FWInventory -Path $p } | Should -Throw "*$Match*"
    }

    It 'rejects other file types and missing files' {
        { Import-FWInventory -Path (Join-Path $TestDrive 'x.txt') } | Should -Throw '*not found*'
        $p = Join-Path $TestDrive 'x.txt'; 'a' | Set-Content $p
        { Import-FWInventory -Path $p } | Should -Throw '*.csv or .json*'
    }
}
