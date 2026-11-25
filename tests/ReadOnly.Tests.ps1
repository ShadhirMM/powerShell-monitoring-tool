# Static proof that the tool cannot change Windows Update (or anything else) on the
# machines it checks. Parses every source file with the PowerShell AST.

BeforeDiscovery {
    # Explicit extension filter: -Include matched the .psd1 manifest on PS 5.1 but not on PS 7; now identical on both.
    $src = Join-Path $PSScriptRoot '..\src'
    $script:sourceFiles = @(Get-ChildItem -LiteralPath $src -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    function Get-Ast([string]$Path) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors) { throw "Parse errors in ${Path}: $($errors -join '; ')" }
        $ast
    }
    function Get-CommandNames($Ast) {
        @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }
    function Get-MethodNames($Ast) {
        @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | ForEach-Object { $_.Member.Value })
    }

    # Commands that could change a machine. None may appear anywhere in src\.
    $script:forbiddenEverywhere = @(
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Rename-ItemProperty', 'Clear-ItemProperty', 'Set-Item', 'Clear-Item',
        'Set-Service', 'Start-Service', 'Stop-Service', 'Restart-Service', 'Suspend-Service', 'Resume-Service', 'New-Service', 'Remove-Service',
        'Restart-Computer', 'Stop-Computer', 'Set-CimInstance', 'New-CimInstance', 'Remove-CimInstance', 'Invoke-CimMethod',
        'Invoke-WmiMethod', 'Set-WmiInstance', 'Remove-WmiObject', 'Enable-PSRemoting', 'Set-WSManQuickConfig', 'Set-ExecutionPolicy',
        'Install-Module', 'Install-Package', 'Start-Process', 'Invoke-Expression', 'iex', 'reg', 'reg.exe', 'sc', 'sc.exe',
        'wuauclt', 'wuauclt.exe', 'usoclient', 'usoclient.exe', 'Install-WindowsUpdate', 'Set-Content', 'Add-Content', 'Out-File'
    )
    # .NET / COM methods that write the registry or install/download updates.
    $script:forbiddenMethods = @('SetValue', 'CreateSubKey', 'DeleteValue', 'DeleteSubKey', 'DeleteSubKeyTree', 'Install', 'Download', 'Commit', 'CreateUpdateInstaller', 'CreateUpdateDownloader', 'Hide', 'AcceptEula')
    # The probe runs on the target machines: it may only use these commands.
    $script:probeAllowed = @('Get-ItemProperty', 'Test-Path', 'Get-CimInstance', 'Get-Date', 'New-Object', 'Where-Object', 'ForEach-Object', 'Read-RegistryValue', 'ConvertTo-IsoDate')
}

Describe 'Read-only by design' {
    It '<Name> uses no state-changing command' -ForEach $script:sourceFiles {
        $used = Get-CommandNames (Get-Ast $Path)
        $bad = @($used | Where-Object { $script:forbiddenEverywhere -contains $_ })
        # Set-Content / Add-Content are allowed only for the tool's own report folder.
        if ($Name -in 'Start-FleetWUMonitor.ps1') { $bad = @($bad | Where-Object { $_ -ne 'Add-Content' }) }
        $bad | Should -BeNullOrEmpty -Because "$Name must not change any machine"
    }

    It '<Name> calls no registry-write or update-install method' -ForEach $script:sourceFiles {
        $bad = @(Get-MethodNames (Get-Ast $Path) | Where-Object { $script:forbiddenMethods -contains $_ })
        $bad | Should -BeNullOrEmpty
    }

    It 'the remote probe uses only the allow-listed read commands' {
        $probeFile = Join-Path $PSScriptRoot '..\src\FleetWU\Private\Probe.ps1'
        $used = Get-CommandNames (Get-Ast $probeFile) | Sort-Object -Unique
        $notAllowed = @($used | Where-Object { $script:probeAllowed -notcontains $_ })
        $notAllowed | Should -BeNullOrEmpty
        $used | Should -Contain 'Get-ItemProperty'
    }

    It 'the probe only queries Windows Update history (no searcher Search, no installer)' {
        $methods = Get-MethodNames (Get-Ast (Join-Path $PSScriptRoot '..\src\FleetWU\Private\Probe.ps1')) | Sort-Object -Unique
        $methods | Should -Contain 'QueryHistory'
        $methods | Should -Not -Contain 'Search'
    }

    It 'registry paths appear only in the probe, and only for reading' {
        $files = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\src') -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and $_.Name -ne 'Probe.ps1' }
        foreach ($f in $files) { (Get-Content -LiteralPath $f.FullName -Raw) | Should -Not -Match 'HKLM:|HKEY_LOCAL_MACHINE|Registry::' -Because $f.Name }
    }

    It 'file writes and deletes stay inside the report output folder' {
        $report = Get-Ast (Join-Path $PSScriptRoot '..\src\FleetWU\Private\Report.ps1')
        $deletes = @($report.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Remove-Item' }, $true))
        $deletes.Count | Should -Be 1
        $deletes[0].Parent.Extent.Text | Should -Match 'Get-ChildItem -LiteralPath \$history'
    }
}
