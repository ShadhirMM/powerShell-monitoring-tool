<#
.SYNOPSIS
    Removes the scheduled task (rollback for Register-FleetWUTask.ps1). Reports are kept.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$TaskName = 'FleetWU Windows Update fleet check')

$ErrorActionPreference = 'Stop'
if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
    Write-Output "Task '$TaskName' is not registered; nothing to do."
    return
}
if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "Removed '$TaskName'. Reports and history were left in place."
}
