function Get-FWMessageSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [int]$MaxMachines = 15)
    $problem = @($Run.Machines | Where-Object Status -NE 'OK')
    $c = $Run.Counts
    $headline = "[$($Run.Status)] Windows Update fleet check: $($c.Total) machine(s): $($c.ALERT) ALERT, $($c.WARNING) WARNING, $($c.OK) OK ($($c.Unreachable) unreachable)"
    $lines = foreach ($m in ($problem | Select-Object -First $MaxMachines)) {
        $worst = @($m.Checks | Where-Object Status -EQ $m.Status | ForEach-Object { "$($_.Check): $($_.Detail)" })
        "$($m.Status) $($m.ComputerName) - $($worst -join '; ')"
    }
    $more = $problem.Count - $MaxMachines
    $trend = $null
    if ($Run.Trend -and $Run.Trend.HasPrevious) {
        $trend = "Since last run: $(@($Run.Trend.New).Count) new, $(@($Run.Trend.Worsened).Count) worse, $(@($Run.Trend.Resolved).Count) resolved, $(@($Run.Trend.Persisting).Count) still failing"
    }
    [pscustomobject]@{ Headline = $headline; Lines = @($lines); More = [math]::Max(0, $more); Trend = $trend }
}

function New-FWWebhookPayload {
    <#
    .SYNOPSIS
        One summary message per run. Lists only machines with WARNING/ALERT.
    .DESCRIPTION
        teams   : Adaptive Card message (Teams "Workflows" webhook)
        slack   : Slack incoming webhook (text + blocks)
        generic : JSON summary for any endpoint (status, counts, trend, problem machines)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Run, [ValidateSet('teams', 'slack', 'generic')][string]$Format = 'teams', [int]$MaxMachines = 15)
    $msg = Get-FWMessageSummary -Run $Run -MaxMachines $MaxMachines
    $body = @($msg.Lines)
    if ($msg.More -gt 0) { $body += "... and $($msg.More) more (see latest.html)" }
    if (-not $body.Count) { $body = @('All machines OK.') }

    switch ($Format) {
        'teams' {
            $color = @{ OK = 'Good'; WARNING = 'Warning'; ALERT = 'Attention' }[$Run.Status]
            $items = @(@{ type = 'TextBlock'; text = $msg.Headline; weight = 'Bolder'; color = $color; wrap = $true })
            if ($msg.Trend) { $items += @{ type = 'TextBlock'; text = $msg.Trend; isSubtle = $true; wrap = $true } }
            foreach ($l in $body) { $items += @{ type = 'TextBlock'; text = "- $l"; wrap = $true; spacing = 'Small' } }
            return @{
                type        = 'message'
                attachments = @(@{
                        contentType = 'application/vnd.microsoft.card.adaptive'
                        content     = @{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'; body = $items }
                    })
            }
        }
        'slack' {
            $text = (@($msg.Headline, $msg.Trend) + ($body | ForEach-Object { "- $_" }) | Where-Object { $_ }) -join "`n"
            return @{
                text   = $text
                blocks = @(
                    @{ type = 'header'; text = @{ type = 'plain_text'; text = "Windows Update fleet: $($Run.Status)" } },
                    @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $text } }
                )
            }
        }
        'generic' {
            return @{
                source   = 'FleetWU'
                runId    = $Run.RunId
                status   = $Run.Status
                summary  = $msg.Headline
                counts   = @{ total = $Run.Counts.Total; ok = $Run.Counts.OK; warning = $Run.Counts.WARNING; alert = $Run.Counts.ALERT; unreachable = $Run.Counts.Unreachable }
                trend    = $msg.Trend
                machines = @($Run.Machines | Where-Object Status -NE 'OK' | Select-Object -First $MaxMachines | ForEach-Object {
                        @{ computerName = $_.ComputerName; group = $_.Group; status = $_.Status
                            findings = @($_.Checks | Where-Object Status -NE 'OK' | ForEach-Object { @{ check = $_.Check; status = $_.Status; detail = $_.Detail } }) }
                    })
            }
        }
    }
}

function Test-FWShouldNotify {
    <# Quiet mode: skip the message when everything is OK and nothing was resolved, unless sendWhenOk. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][hashtable]$Config)
    if ($Run.Status -ne 'OK') { return $true }
    if ($Config.webhook.sendWhenOk) { return $true }
    [bool]($Run.Trend -and @($Run.Trend.Resolved).Count -gt 0)
}

function Send-FWWebhook {
    <#
    .SYNOPSIS
        POSTs the payload with retries. Returns a result object; never throws.
    .DESCRIPTION
        Retries network errors, HTTP 429 and 5xx (honouring Retry-After up to 300 s).
        Other 4xx responses are permanent and are not retried.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][hashtable]$Payload,
        [Parameter(Mandatory)][hashtable]$Webhook,
        [scriptblock]$Sleep = { param($s) Start-Sleep -Seconds $s }
    )
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $request = @{ Uri = $Url; Method = 'Post'; Body = $bytes; ContentType = 'application/json; charset=utf-8'; TimeoutSec = $Webhook.timeoutSec; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -lt 6) { $request.UseBasicParsing = $true }   # avoids the IE engine on Windows PowerShell 5.1
            $null = Invoke-RestMethod @request
            return [pscustomobject]@{ Sent = $true; Attempts = $attempt; Error = $null }
        } catch {
            $status = $null; $retryAfter = $null
            $response = $null
            if ($_.Exception.PSObject.Properties['Response']) { $response = $_.Exception.Response }
            if ($response) {
                $status = [int]$response.StatusCode
                $ra = $null
                # PS 5.1: WebHeaderCollection; PS 7: HttpResponseHeaders. Either may be absent.
                try { $ra = $response.Headers['Retry-After'] } catch { $ra = $null }
                if (-not $ra) { try { $ra = [int]$response.Headers.RetryAfter.Delta.TotalSeconds } catch { $ra = $null } }
                if ($ra -and "$ra" -match '^\d+$') { $retryAfter = [math]::Min([int]"$ra", 300) }
            }
            $temporary = (-not $status) -or $status -eq 429 -or $status -ge 500
            if (-not $temporary -or $attempt -gt $Webhook.retries) {
                return [pscustomobject]@{ Sent = $false; Attempts = $attempt; Error = "$(if ($status) { "HTTP $status " })$($_.Exception.Message)" }
            }
            $delay = if ($retryAfter) { $retryAfter } else { @($Webhook.retryDelaySec)[$attempt - 1] }
            & $Sleep $delay
        }
    }
}
