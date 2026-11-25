# Shared test data: probe "facts" for many machine states (fictional machines).
# Dates are relative to Get-TestNow so the tests never go stale.

function Get-TestNow { [datetime]::new(2026, 11, 25, 6, 0, 0, [DateTimeKind]::Utc) }

function New-TestHistory {
    param([int]$DaysAgo = 10, [string]$Title = '2026-11 Cumulative Update for Windows 11 (KB5099001)', [int]$ResultCode = 2)
    [pscustomobject]@{ Title = $Title; Date = (Get-TestNow).AddDays(-$DaysAgo).ToString('o'); ResultCode = $ResultCode; Operation = 1; HResult = '0x00000000' }
}

function New-TestFacts {
    <# Healthy machine by default; pass a scriptblock to change it: New-TestFacts { $f.Policy.NoAutoUpdate = 1 } #>
    param($Name = 'OFFICE-PC-01', [scriptblock]$Change)
    if ($Name -is [scriptblock]) { $Change = $Name; $Name = 'OFFICE-PC-01' }   # New-TestFacts { ... }
    $f = [pscustomobject]@{
        ComputerName  = $Name
        CollectedAt   = (Get-TestNow).ToString('o')
        ProbeVersion  = '1.0.0'
        Os            = @{ Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26200'; Build = '26200'; UBR = 7171; DisplayVersion = '25H2'; LastBootUpTime = (Get-TestNow).AddDays(-2).ToString('o') }
        Services      = @{ wuauserv = 'Manual'; UsoSvc = 'Auto'; WaaSMedicSvc = 'Manual' }
        Policy        = @{}
        Pause         = @{}
        Reboot        = @{ WindowsUpdate = $false; ComponentBasedServicing = $false }
        History       = @(
            (New-TestHistory -DaysAgo 10),
            (New-TestHistory -DaysAgo 12 -Title 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602'),
            (New-TestHistory -DaysAgo 40 -Title '2026-10 Cumulative Update for Windows 11 (KB5098001)')
        )
        HistorySource = 'WUA'
        Errors        = @()
    }
    # Run the change with `$f bound explicitly (scriptblocks may come from another scope, e.g. Pester discovery).
    if ($Change) {
        $vars = New-Object 'System.Collections.Generic.List[psvariable]'
        $vars.Add([psvariable]::new('f', $f))
        $null = $Change.InvokeWithContext($null, $vars)
    }
    $f
}

function Get-TestScenario {
    <# Named machine states used across the tests. Each returns facts + the expected check result. #>
    @(
        @{ Name = 'healthy'; Check = 'UpdateServices'; Status = 'OK'; Facts = (New-TestFacts) }
        @{ Name = 'wuauserv disabled'; Check = 'UpdateServices'; Status = 'ALERT'; Facts = (New-TestFacts { $f.Services.wuauserv = 'Disabled' }) }
        @{ Name = 'UsoSvc missing'; Check = 'UpdateServices'; Status = 'ALERT'; Facts = (New-TestFacts { $f.Services.UsoSvc = 'Missing' }) }
        @{ Name = 'medic disabled'; Check = 'UpdateServices'; Status = 'WARNING'; Facts = (New-TestFacts { $f.Services.WaaSMedicSvc = 'Disabled' }) }
        @{ Name = 'services unreadable'; Check = 'UpdateServices'; Status = 'WARNING'; Facts = (New-TestFacts { $f.Services = @{} }) }
        @{ Name = 'NoAutoUpdate'; Check = 'AutomaticUpdates'; Status = 'ALERT'; Facts = (New-TestFacts { $f.Policy.NoAutoUpdate = 1 }) }
        @{ Name = 'AUOptions 3'; Check = 'AutomaticUpdates'; Status = 'WARNING'; Facts = (New-TestFacts { $f.Policy.AUOptions = 3 }) }
        @{ Name = 'AUOptions 4'; Check = 'AutomaticUpdates'; Status = 'OK'; Facts = (New-TestFacts { $f.Policy.AUOptions = 4 }) }
        @{ Name = 'AUOptions 9'; Check = 'AutomaticUpdates'; Status = 'WARNING'; Facts = (New-TestFacts { $f.Policy.AUOptions = 9 }) }
        @{ Name = 'paused 3 days'; Check = 'UpdatePause'; Status = 'WARNING'; Facts = (New-TestFacts { $f.Pause.PauseUpdatesExpiryTime = (Get-TestNow).AddDays(3).ToString('yyyy-MM-ddTHH:mm:ssZ') }) }
        @{ Name = 'paused 21 days'; Check = 'UpdatePause'; Status = 'ALERT'; Facts = (New-TestFacts { $f.Pause.PauseQualityUpdatesEndTime = (Get-TestNow).AddDays(21).ToString('yyyy-MM-ddTHH:mm:ssZ') }) }
        @{ Name = 'pause expired'; Check = 'UpdatePause'; Status = 'OK'; Facts = (New-TestFacts { $f.Pause.PauseUpdatesExpiryTime = (Get-TestNow).AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ') }) }
        @{ Name = 'policy pause'; Check = 'UpdatePause'; Status = 'ALERT'; Facts = (New-TestFacts { $f.Policy.PauseQualityUpdatesStartTime = (Get-TestNow).AddDays(-5).ToString('yyyy-MM-dd') }) }
        @{ Name = 'deferral 10'; Check = 'Deferral'; Status = 'WARNING'; Facts = (New-TestFacts { $f.Policy.DeferQualityUpdates = 1; $f.Policy.DeferQualityUpdatesPeriodInDays = 10 }) }
        @{ Name = 'deferral 30'; Check = 'Deferral'; Status = 'ALERT'; Facts = (New-TestFacts { $f.Policy.DeferQualityUpdates = 1; $f.Policy.DeferQualityUpdatesPeriodInDays = 30 }) }
        @{ Name = 'feature deferral 365'; Check = 'Deferral'; Status = 'WARNING'; Facts = (New-TestFacts { $f.Policy.DeferFeatureUpdates = 1; $f.Policy.DeferFeatureUpdatesPeriodInDays = 365 }) }
        @{ Name = 'deferral switched off'; Check = 'Deferral'; Status = 'OK'; Facts = (New-TestFacts { $f.Policy.DeferQualityUpdates = 0; $f.Policy.DeferQualityUpdatesPeriodInDays = 30 }) }
        @{ Name = 'approved WSUS'; Check = 'UpdateSource'; Status = 'OK'; Facts = (New-TestFacts { $f.Policy.UseWUServer = 1; $f.Policy.WUServer = 'https://wsus.familyoffice-demo.example:8531/' }) }
        @{ Name = 'unknown WSUS'; Check = 'UpdateSource'; Status = 'WARNING'; Facts = (New-TestFacts { $f.Policy.UseWUServer = 1; $f.Policy.WUServer = 'http://old-wsus.example:8530' }) }
        @{ Name = 'no source'; Check = 'UpdateSource'; Status = 'ALERT'; Facts = (New-TestFacts { $f.Policy.DoNotConnectToWindowsUpdateInternetLocations = 1 }) }
        @{ Name = 'update 40 days'; Check = 'LastQualityUpdate'; Status = 'WARNING'; Facts = (New-TestFacts { $f.History = @(New-TestHistory -DaysAgo 40) }) }
        @{ Name = 'update 90 days'; Check = 'LastQualityUpdate'; Status = 'ALERT'; Facts = (New-TestFacts { $f.History = @(New-TestHistory -DaysAgo 90) }) }
        @{ Name = 'only preview + defender'; Check = 'LastQualityUpdate'; Status = 'WARNING'; Facts = (New-TestFacts { $f.History = @((New-TestHistory -DaysAgo 2 -Title '2026-11 Cumulative Update Preview for Windows 11 (KB5099100)'), (New-TestHistory -DaysAgo 1 -Title 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602')) }) }
        @{ Name = 'history unreadable'; Check = 'LastQualityUpdate'; Status = 'WARNING'; Facts = (New-TestFacts { $f.History = @(); $f.HistorySource = 'None' }) }
        @{ Name = 'QFE fallback'; Check = 'LastQualityUpdate'; Status = 'OK'; Facts = (New-TestFacts { $f.HistorySource = 'QFE'; $f.History = @(New-TestHistory -DaysAgo 5 -Title 'Security Update KB5099001') }) }
        @{ Name = '1 failure'; Check = 'RecentFailures'; Status = 'WARNING'; Facts = (New-TestFacts { $f.History += (New-TestHistory -DaysAgo 3 -Title '2026-11 .NET Update (KB5099002)' -ResultCode 4) }) }
        @{ Name = '3 failures'; Check = 'RecentFailures'; Status = 'ALERT'; Facts = (New-TestFacts { $f.History += @((New-TestHistory -DaysAgo 3 -Title 'A (KB5000001)' -ResultCode 4), (New-TestHistory -DaysAgo 4 -Title 'B (KB5000002)' -ResultCode 4), (New-TestHistory -DaysAgo 5 -Title 'C (KB5000003)' -ResultCode 5)) }) }
        @{ Name = 'failure fixed later'; Check = 'RecentFailures'; Status = 'OK'; Facts = (New-TestFacts { $f.History += @((New-TestHistory -DaysAgo 6 -Title 'A (KB5000001)' -ResultCode 4), (New-TestHistory -DaysAgo 2 -Title 'A (KB5000001)' -ResultCode 2)) }) }
        @{ Name = 'old failure'; Check = 'RecentFailures'; Status = 'OK'; Facts = (New-TestFacts { $f.History += (New-TestHistory -DaysAgo 45 -Title 'A (KB5000001)' -ResultCode 4) }) }
        @{ Name = 'reboot pending 2d'; Check = 'PendingReboot'; Status = 'WARNING'; Facts = (New-TestFacts { $f.Reboot.WindowsUpdate = $true }) }
        @{ Name = 'reboot pending 9d'; Check = 'PendingReboot'; Status = 'ALERT'; Facts = (New-TestFacts { $f.Reboot.ComponentBasedServicing = $true; $f.Os.LastBootUpTime = (Get-TestNow).AddDays(-9).ToString('o') }) }
    )
}

function New-TestFleetCollection {
    <# A small fictional fleet: one healthy, one ALERT, one WARNING, one unreachable. #>
    @(
        [pscustomobject]@{ ComputerName = 'OFFICE-PC-01'; Reachability = 'Online'; Facts = (New-TestFacts 'OFFICE-PC-01'); ErrorMessage = $null; Seconds = 2.1 }
        [pscustomobject]@{ ComputerName = 'OFFICE-PC-02'; Reachability = 'Online'; Facts = (New-TestFacts 'OFFICE-PC-02' { $f.Pause.PauseUpdatesExpiryTime = (Get-TestNow).AddDays(21).ToString('yyyy-MM-ddTHH:mm:ssZ') }); ErrorMessage = $null; Seconds = 2.4 }
        [pscustomobject]@{ ComputerName = 'RES-MEDIA-01'; Reachability = 'Online'; Facts = (New-TestFacts 'RES-MEDIA-01' { $f.Reboot.WindowsUpdate = $true }); ErrorMessage = $null; Seconds = 3.0 }
        [pscustomobject]@{ ComputerName = 'OFFICE-LT-03'; Reachability = 'Unreachable'; Facts = $null; ErrorMessage = 'WinRM cannot complete the operation.'; Seconds = 15.0 }
    )
}

function New-TestMachines {
    param([string[]]$Names = @('OFFICE-PC-01', 'OFFICE-PC-02', 'RES-MEDIA-01', 'OFFICE-LT-03'))
    foreach ($n in $Names) {
        [pscustomobject]@{ ComputerName = $n; Group = if ($n -like 'RES-*') { 'Residence' } else { 'Office' }; Tags = @(); Transport = 'Remote'; Enabled = $true; Notes = '' }
    }
}
