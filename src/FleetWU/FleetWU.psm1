# FleetWU: read-only Windows Update settings monitor for a fleet of machines.
Set-StrictMode -Version 2.0
$script:FWVersion = '1.0.0'

foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' | Sort-Object Name) {
        . $file.FullName
    }
}

Export-ModuleMember -Function 'Invoke-FleetWUMonitor', 'Format-FWConsoleReport', 'Import-FWInventory', 'Get-FWConfig', 'Test-FWConfig'
