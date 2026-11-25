<#
.SYNOPSIS
    Registers the weekly scheduled task that runs the fleet check.

.DESCRIPTION
    Pre-flight first: the config must be valid, the inventory must load and the
    output folder must be writable, otherwise nothing is registered.
    The task runs src\Start-FleetWUMonitor.ps1 with Windows PowerShell 5.1:
      - weekly (default Monday 07:00), starts when available if the PC was off,
      - never two runs at once, stopped after 2 hours,
      - exit code = status (0 OK, 1 WARNING, 2 ALERT, 3 run failed) in "Last Run Result".
    Use -WhatIf to preview. Remove with Unregister-FleetWUTask.ps1.

    To run without anyone logged on, pass -RunAsUser with a dedicated monitoring
    account (you are asked for its password; Windows stores it) or use a gMSA
    (see docs/INSTALL.md).

.EXAMPLE
    .\install\Register-FleetWUTask.ps1 -InventoryPath C:\FleetWU\inventory.csv -WhatIf
.EXAMPLE
    .\install\Register-FleetWUTask.ps1 -InventoryPath C:\FleetWU\inventory.csv -Day Friday -Time 16:00 -RunAsUser 'CORP\svc-fleetwu'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InventoryPath,
    [string]$ConfigPath,
    [string]$OutputDir,
    [string]$TaskName = 'FleetWU Windows Update fleet check',
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')][string]$Day = 'Monday',
    [ValidatePattern('^\d{2}:\d{2}$')][string]$Time = '07:00',
    [string]$RunAsUser
)

$ErrorActionPreference = 'Stop'
# Defaults set here: PS 5.1 leaves $PSScriptRoot empty in param() defaults under 'powershell -File'.
$root = Split-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -Parent
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\fleetwu.config.json' }
if (-not $OutputDir) { $OutputDir = Join-Path $root 'reports' }
$entry = Join-Path $root 'src\Start-FleetWUMonitor.ps1'
Import-Module (Join-Path $root 'src\FleetWU\FleetWU.psd1') -Force

# ---- Pre-flight -----------------------------------------------------------
$InventoryPath = (Resolve-Path -LiteralPath $InventoryPath).Path
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Get-FWConfig -Path $ConfigPath                       # throws if invalid
$machines = Import-FWInventory -Path $InventoryPath            # throws if invalid
if (-not $machines.Count) { throw "The inventory has no enabled machines: $InventoryPath" }
$null = New-Item -ItemType Directory -Path $OutputDir -Force -WhatIf:$false
$probe = Join-Path $OutputDir '.write-test'
Set-Content -LiteralPath $probe -Value 'ok' -WhatIf:$false
Remove-Item -LiteralPath $probe -WhatIf:$false
if (-not [Environment]::GetEnvironmentVariable($config.webhook.urlEnvVar, 'Machine') -and -not [Environment]::GetEnvironmentVariable($config.webhook.urlEnvVar, 'User')) {
    Write-Warning "$($config.webhook.urlEnvVar) is not set for the task account: reports will be written but no webhook will be sent."
}
Write-Output "Pre-flight OK: config valid, $($machines.Count) machine(s) in the inventory, output folder writable."

# ---- Task -------------------------------------------------------------------
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$entry`" -InventoryPath `"$InventoryPath`" -ConfigPath `"$ConfigPath`" -OutputDir `"$OutputDir`" -Quiet"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $Time
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -RunOnlyIfNetworkAvailable
$description = "Read-only Windows Update settings check for $($machines.Count) machine(s). Reports: $OutputDir. Registered $(Get-Date -Format s)."

if ($PSCmdlet.ShouldProcess($TaskName, "Register weekly task ($Day $Time): powershell.exe $arguments")) {
    $register = @{ TaskName = $TaskName; Action = $action; Trigger = $trigger; Settings = $settings; Description = $description; Force = $true }
    if ($RunAsUser) {
        $cred = Get-Credential -UserName $RunAsUser -Message 'Password for the monitoring account (stored by Task Scheduler)'
        $register.User = $cred.UserName
        $register.Password = $cred.GetNetworkCredential().Password
        $register.RunLevel = 'Limited'
    }
    Register-ScheduledTask @register | Out-Null
    Write-Output "Registered '$TaskName'. Next run: $((Get-ScheduledTaskInfo -TaskName $TaskName).NextRunTime)"
    Write-Output "Test now:  Start-ScheduledTask -TaskName '$TaskName'"
}
