BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\FleetWU\FleetWU.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Error classification' {
    It '<Message> -> <Kind>' -ForEach @(
        @{ Message = 'Connecting to remote server PC-9 failed with the following error message : Access is denied.'; Kind = 'AccessDenied' }
        @{ Message = 'The WinRM client cannot complete the operation within the time specified.'; Kind = 'Timeout' }
        @{ Message = 'WinRM cannot complete the operation. Verify that the specified computer name is valid'; Kind = 'Unreachable' }
        @{ Message = 'Connecting to remote server PC-9 failed: The network path was not found.'; Kind = 'Unreachable' }
        @{ Message = 'Something unexpected'; Kind = 'Error' }
    ) {
        InModuleScope FleetWU -Parameters @{ M = $Message } { param($M) Get-FWErrorKind $M } | Should -Be $Kind
    }

    It 'shortens long WinRM messages to the first sentence' {
        $long = 'Connecting to remote server X failed with the following error message : The WinRM client cannot process the request. If the authentication scheme is different from Kerberos, then HTTPS transport must be used.'
        $short = InModuleScope FleetWU -Parameters @{ M = $long } { param($M) Format-FWErrorMessage $M }
        $short | Should -Be 'Connecting to remote server X failed with the following error message : The WinRM client cannot process the request.'
        (InModuleScope FleetWU { Format-FWErrorMessage ('x' * 500) }).Length | Should -Be 200
    }
}

Describe 'Collection' {
    BeforeAll { $script:config = InModuleScope FleetWU { Get-FWDefaultConfig } }

    It 'runs Local machines in-process and Remote machines in one parallel batch' {
        $machines = @(
            [pscustomobject]@{ ComputerName = 'localhost'; Transport = 'Local' }
            [pscustomobject]@{ ComputerName = 'PC-A'; Transport = 'Remote' }
            [pscustomobject]@{ ComputerName = 'PC-B'; Transport = 'Remote' }
        )
        $r = InModuleScope FleetWU -Parameters @{ Machines = $machines; Config = $script:config } {
            param($Machines, $Config)
            Mock Invoke-FWLocalProbe { New-FWCollectionResult -ComputerName $ComputerName -Reachability 'Online' -Facts 'local' }
            Mock Invoke-FWRemoteProbe {
                @(
                    New-FWCollectionResult -ComputerName 'PC-A' -Reachability 'Online' -Facts 'remote'
                    New-FWCollectionResult -ComputerName 'PC-B' -Reachability 'AccessDenied' -ErrorMessage 'Access is denied.'
                )
            }
            $out = Invoke-FWCollection -Machines $Machines -Config $Config
            Should -Invoke Invoke-FWRemoteProbe -Times 1 -Exactly -ParameterFilter { $ComputerName.Count -eq 2 }
            Should -Invoke Invoke-FWLocalProbe -Times 1 -Exactly
            $out
        }
        $r.Count | Should -Be 3
        ($r | Where-Object ComputerName -EQ 'PC-B').Reachability | Should -Be 'AccessDenied'
    }

    It 'a machine missing from the remoting results is reported, not lost' {
        $machines = @([pscustomobject]@{ ComputerName = 'PC-A'; Transport = 'Remote' }, [pscustomobject]@{ ComputerName = 'PC-GONE'; Transport = 'Remote' })
        $r = InModuleScope FleetWU -Parameters @{ Machines = $machines; Config = $script:config } {
            param($Machines, $Config)
            Mock Invoke-FWRemoteProbe { @(New-FWCollectionResult -ComputerName 'pc-a' -Reachability 'Online' -Facts 'x') }
            Invoke-FWCollection -Machines $Machines -Config $Config
        }
        $r.Count | Should -Be 2
        ($r | Where-Object ComputerName -EQ 'PC-GONE').Reachability | Should -Be 'Error'
    }

    It 'if Invoke-Command cannot even start, every machine gets the classified error' {
        $r = InModuleScope FleetWU -Parameters @{ Config = $script:config } {
            param($Config)
            Mock Invoke-Command { throw 'Access is denied.' }
            Invoke-FWRemoteProbe -ComputerName @('PC-A', 'PC-B') -Remote $Config.remote
        }
        $r.Count | Should -Be 2
        $r.Reachability | Should -Be @('AccessDenied', 'AccessDenied')
    }

    It 'a local probe that throws is classified, not fatal' {
        $r = InModuleScope FleetWU {
            Mock Get-FWProbe { { throw 'The RPC server is unavailable' } }
            Invoke-FWLocalProbe -ComputerName 'localhost'
        }
        $r.Reachability | Should -Be 'Error'
        $r.ErrorMessage | Should -Match 'RPC'
    }

    It 'passes credential, throttle and timeouts to Invoke-Command' {
        $cred = [pscredential]::new('FLEET\svc-monitor', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        InModuleScope FleetWU -Parameters @{ Config = $script:config; Cred = $cred } {
            param($Config, $Cred)
            Mock Invoke-Command { throw 'stop here' }
            $null = Invoke-FWRemoteProbe -ComputerName 'PC-A' -Remote $Config.remote -Credential $Cred
            Should -Invoke Invoke-Command -Times 1 -ParameterFilter {
                $AsJob -and $ThrottleLimit -eq 16 -and $Credential.UserName -eq 'FLEET\svc-monitor' -and $SessionOption.OperationTimeout.TotalSeconds -eq 120
            }
        }
    }
}

Describe 'Real collection (no system changes)' {
    It 'probes this machine through the Local transport' {
        $r = InModuleScope FleetWU { Invoke-FWLocalProbe -ComputerName 'localhost' }
        $r.Reachability | Should -Be 'Online'
        $r.Facts.Os.Build | Should -Match '^\d+$'
        $r.Facts.Services.Keys | Should -Contain 'wuauserv'
        $r.Facts.HistorySource | Should -BeIn @('WUA', 'QFE', 'None')
    }

    It 'an unresolvable host over WinRM is reported as a failure, not a crash' {
        $cfg = InModuleScope FleetWU { Get-FWDefaultConfig }
        $cfg.remote.openTimeoutSec = 5
        $cfg.remote.totalTimeoutSec = 60
        $r = InModuleScope FleetWU -Parameters @{ Remote = $cfg.remote } {
            param($Remote) Invoke-FWRemoteProbe -ComputerName 'nohost-fleetwu.invalid' -Remote $Remote
        }
        @($r).Count | Should -Be 1
        $r.Reachability | Should -BeIn @('Unreachable', 'Error', 'AccessDenied', 'Timeout')
        $r.Reachability | Should -Not -Be 'Online'
        $r.ErrorMessage | Should -Not -BeNullOrEmpty
    }
}
