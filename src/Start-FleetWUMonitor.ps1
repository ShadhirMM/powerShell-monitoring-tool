<#
.SYNOPSIS
    Entry point for the scheduled task: runs the fleet check and sets the exit code.

.DESCRIPTION
    Exit codes (Task Scheduler "Last Run Result"):
      0 = OK, 1 = WARNING, 2 = ALERT, 3 = the run itself failed (bad config/inventory, crash).
    A one-line summary of every run is appended to <OutputDir>\fleetwu.log.

.EXAMPLE
    .\src\Start-FleetWUMonitor.ps1 -InventoryPath .\config\inventory.csv -ConfigPath .\config\fleetwu.config.json
.EXAMPLE
    .\src\Start-FleetWUMonitor.ps1 -InventoryPath .\config\inventory.csv -Group Office -NoWebhook
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InventoryPath,
    [string]$ConfigPath,
    [string]$OutputDir,
    [string[]]$Group,
    [string[]]$Tag,
    [pscredential]$Credential,
    [switch]$NoWebhook,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
# Defaults are set here, not in param(): Windows PowerShell 5.1 leaves $PSScriptRoot empty
# while evaluating parameter defaults when started with 'powershell -File'.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $here -Parent) 'reports' }
Import-Module (Join-Path $here 'FleetWU\FleetWU.psd1') -Force

$null = New-Item -ItemType Directory -Path $OutputDir -Force
$log = Join-Path $OutputDir 'fleetwu.log'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

try {
    $params = @{ InventoryPath = $InventoryPath; OutputDir = $OutputDir; NoWebhook = $NoWebhook }
    if ($ConfigPath) { $params.ConfigPath = $ConfigPath }
    if ($Group) { $params.Group = $Group }
    if ($Tag) { $params.Tag = $Tag }
    if ($Credential) { $params.Credential = $Credential }
    $run = Invoke-FleetWUMonitor @params

    if (-not $Quiet) { Write-Output (Format-FWConsoleReport -Run $run) }
    $hook = if ($run.Webhook.Sent) { "sent ($($run.Webhook.Attempts) attempt(s))" } elseif ($run.Webhook.Skipped) { "skipped: $($run.Webhook.Skipped)" } else { "FAILED: $($run.Webhook.Error)" }
    Add-Content -LiteralPath $log -Value "$stamp $($run.Status) run=$($run.RunId) machines=$($run.Counts.Total) alert=$($run.Counts.ALERT) warning=$($run.Counts.WARNING) unreachable=$($run.Counts.Unreachable) webhook=$hook" -Encoding UTF8
    if (-not $Quiet) { Write-Output "Report: $($run.Files.Html)"; Write-Output "Webhook: $hook" }
    exit @{ OK = 0; WARNING = 1; ALERT = 2 }[$run.Status]
} catch {
    Add-Content -LiteralPath $log -Value "$stamp FAILED $($_.Exception.Message)" -Encoding UTF8
    Write-Error "FleetWU run failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 3
}
