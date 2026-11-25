@{
    RootModule        = 'FleetWU.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '6f1c2d8e-4b7a-4f43-9a0e-2d5c7b9e1f30'
    Author            = 'Mushaff Shadhir'
    Copyright         = '(c) 2026 Mushaff Shadhir. MIT License.'
    Description       = 'Read-only Windows Update settings monitor for a fleet of machines: parallel WinRM collection, HTML/CSV/JSON reports with trend, webhook alerts.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-FleetWUMonitor', 'Format-FWConsoleReport', 'Import-FWInventory', 'Get-FWConfig', 'Test-FWConfig')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('WindowsUpdate', 'Monitoring', 'Fleet', 'WinRM', 'Webhook'); LicenseUri = 'https://github.com/ShadhirMM/powerShell-monitoring-tool/blob/main/LICENSE' } }
}
