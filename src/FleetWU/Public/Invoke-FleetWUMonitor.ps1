function Invoke-FleetWUMonitor {
    <#
    .SYNOPSIS
        Checks Windows Update settings on every machine in the inventory, writes the
        reports, compares with the previous run and sends one webhook summary.
    .DESCRIPTION
        Read-only: nothing is changed on any machine. Returns the run object.
    .EXAMPLE
        Invoke-FleetWUMonitor -InventoryPath .\config\inventory.csv -OutputDir .\reports
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InventoryPath,
        [string]$ConfigPath,
        [string]$OutputDir = (Join-Path (Get-Location) 'reports'),
        [string[]]$Group,
        [string[]]$Tag,
        [pscredential]$Credential,
        [switch]$NoWebhook,
        [string]$WebhookUrl
    )
    $started = (Get-Date).ToUniversalTime()
    $config = Get-FWConfig -Path $ConfigPath
    $machines = Import-FWInventory -Path $InventoryPath -Group $Group -Tag $Tag
    if (-not $machines.Count) { throw 'The inventory selection is empty (check -Group / -Tag and the Enabled column).' }

    if (-not $Credential -and $config.remote.credentialPath) {
        if (-not (Test-Path -LiteralPath $config.remote.credentialPath)) { throw "Credential file not found: $($config.remote.credentialPath)" }
        $Credential = Import-Clixml -LiteralPath $config.remote.credentialPath
    }

    Write-Verbose "Checking $($machines.Count) machine(s)"
    $collections = Invoke-FWCollection -Machines $machines -Config $config -Credential $Credential
    $previous = Get-FWPreviousRun -HistoryDir (Join-Path $OutputDir 'history')
    $run = New-FWRun -Machines $machines -Collections $collections -Config $config -Now (Get-Date).ToUniversalTime() -StartedAt $started -PreviousRun $previous

    $files = Save-FWRun -Run $run -OutputDir $OutputDir -KeepRuns $config.report.keepRuns

    $delivery = [pscustomobject]@{ Sent = $false; Attempts = 0; Error = $null; Skipped = $null }
    if (-not $WebhookUrl) { $WebhookUrl = [Environment]::GetEnvironmentVariable($config.webhook.urlEnvVar) }
    if ($NoWebhook) { $delivery.Skipped = 'disabled (-NoWebhook)' }
    elseif (-not $WebhookUrl) { $delivery.Skipped = "no URL (set the $($config.webhook.urlEnvVar) environment variable)" }
    elseif (-not (Test-FWShouldNotify -Run $run -Config $config)) { $delivery.Skipped = 'quiet mode: all OK, nothing changed' }
    else {
        $payload = New-FWWebhookPayload -Run $run -Format $config.webhook.format -MaxMachines $config.webhook.maxMachines
        $r = Send-FWWebhook -Url $WebhookUrl -Payload $payload -Webhook $config.webhook
        $delivery.Sent = $r.Sent; $delivery.Attempts = $r.Attempts; $delivery.Error = $r.Error
        if (-not $r.Sent) { Write-Warning "Webhook delivery failed after $($r.Attempts) attempt(s): $($r.Error)" }
    }

    $run | Add-Member -NotePropertyName Files -NotePropertyValue $files
    $run | Add-Member -NotePropertyName Webhook -NotePropertyValue $delivery
    $run
}

function Format-FWConsoleReport {
    <# Plain-text summary for the console / scheduled-task log. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Run)
    $lines = @("FleetWU run $($Run.RunId): $($Run.Status)  ($($Run.Counts.Total) machines: $($Run.Counts.ALERT) ALERT, $($Run.Counts.WARNING) WARNING, $($Run.Counts.OK) OK, $($Run.Counts.Unreachable) unreachable)")
    foreach ($m in $Run.Machines) {
        $lines += ('  {0,-7} {1,-18} {2}' -f $m.Status, $m.ComputerName, $m.Os)
        foreach ($c in @($m.Checks | Where-Object Status -NE 'OK')) { $lines += ('           [{0,-7}] {1,-17} {2}' -f $c.Status, $c.Check, $c.Detail) }
    }
    if ($Run.Trend -and $Run.Trend.HasPrevious) {
        $lines += "  Since $($Run.Trend.PreviousRunId): $(@($Run.Trend.New).Count) new, $(@($Run.Trend.Worsened).Count) worse, $(@($Run.Trend.Resolved).Count) resolved, $(@($Run.Trend.Persisting).Count) still failing"
    }
    $lines -join [Environment]::NewLine
}
