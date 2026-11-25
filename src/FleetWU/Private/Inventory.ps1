function Import-FWInventory {
    <#
    .SYNOPSIS
        Loads the machine inventory from CSV or JSON.
    .DESCRIPTION
        Columns/fields: ComputerName (required), Group, Tags (semicolon-separated in CSV,
        array in JSON), Transport (Local | Remote; default Remote, or Local for '.',
        'localhost' and this computer's name), Enabled (default true), Notes.
        Filters by -Group / -Tag. Throws on an empty, duplicate or invalid name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Group,
        [string[]]$Tag
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Inventory file not found: $Path" }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $rows = switch ($ext) {
        '.csv' { @(Import-Csv -LiteralPath $Path) }
        '.json' { @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
        default { throw "Inventory must be .csv or .json: $Path" }
    }

    $local = @('.', 'localhost', $env:COMPUTERNAME.ToLowerInvariant())
    $seen = @{}
    $machines = foreach ($row in $rows) {
        # Optional columns may be missing (Set-StrictMode): read every field through one safe lookup.
        $r = @{}
        foreach ($f in 'ComputerName', 'Group', 'Tags', 'Transport', 'Enabled', 'Notes') {
            $prop = $row.PSObject.Properties[$f]
            $r[$f] = if ($prop) { $prop.Value } else { $null }
        }
        $name = ([string]$r.ComputerName).Trim()
        if (-not $name) { throw "Inventory row without ComputerName in $Path" }
        if ($name -notmatch '^[A-Za-z0-9.\-_]{1,253}$') { throw "Invalid ComputerName '$name' in $Path" }
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { throw "Duplicate ComputerName '$name' in $Path" }
        $seen[$key] = $true

        $enabled = $true
        if ($null -ne $r.Enabled -and "$($r.Enabled)" -ne '') { $enabled = "$($r.Enabled)" -match '^(true|1|yes)$' }
        $tags = @()
        if ($r.Tags -is [array]) { $tags = @($r.Tags) }
        elseif ($r.Tags) { $tags = @("$($r.Tags)" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $transport = if ($r.Transport) { "$($r.Transport)" } elseif ($local -contains $key) { 'Local' } else { 'Remote' }
        if ($transport -notin 'Local', 'Remote') { throw "Invalid Transport '$transport' for '$name' (use Local or Remote)" }

        [pscustomobject]@{
            ComputerName = $name
            Group        = if ($r.Group) { "$($r.Group)" } else { 'Default' }
            Tags         = $tags
            Transport    = $transport
            Enabled      = $enabled
            Notes        = "$($r.Notes)"
        }
    }
    $machines = @($machines | Where-Object Enabled)
    if ($Group) { $machines = @($machines | Where-Object { $Group -contains $_.Group }) }
    if ($Tag) { $machines = @($machines | Where-Object { @($_.Tags | Where-Object { $Tag -contains $_ }).Count -gt 0 }) }
    , $machines
}
