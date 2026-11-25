function Get-FWErrorKind {
    <# Classifies a collection failure from its message / error id. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Message, [string]$ErrorId)
    $text = "$Message $ErrorId"
    if ($text -match 'Access is denied|AccessDenied|UnauthorizedAccess|0x80070005') { return 'AccessDenied' }
    if ($text -match 'timed out|timeout|within the time specified|OperationTimeout|0x80338029') { return 'Timeout' }
    if ($text -match 'cannot be resolved|cannot find the computer|could not be resolved|CannotConnect|cannot connect|network path|WinRM cannot complete|Connecting to remote server .* failed|No such host|unreachable|0x80338012|0x803380E4') { return 'Unreachable' }
    'Error'
}

function Format-FWErrorMessage {
    <# First sentence of a (often very long) WinRM error, max 200 characters. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Message)
    $m = ($Message -replace '\s+', ' ').Trim()
    $cut = $m.IndexOf('. ', [math]::Min(40, $m.Length))
    if ($cut -gt 0) { $m = $m.Substring(0, $cut + 1) }
    if ($m.Length -gt 200) { $m = $m.Substring(0, 197) + '...' }
    $m
}

function New-FWCollectionResult {
    [CmdletBinding()]
    param([string]$ComputerName, [string]$Reachability, $Facts, [string]$ErrorMessage, [double]$Seconds)
    [pscustomobject]@{
        ComputerName = $ComputerName
        Reachability = $Reachability     # Online | Unreachable | AccessDenied | Timeout | Error
        Facts        = $Facts
        ErrorMessage = if ($ErrorMessage) { Format-FWErrorMessage $ErrorMessage } else { $null }
        Seconds      = [math]::Round($Seconds, 1)
    }
}

function Invoke-FWLocalProbe {
    <# Runs the probe on this machine, in-process. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ComputerName)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $facts = & (Get-FWProbe)
        New-FWCollectionResult -ComputerName $ComputerName -Reachability 'Online' -Facts $facts -Seconds $sw.Elapsed.TotalSeconds
    } catch {
        New-FWCollectionResult -ComputerName $ComputerName -Reachability (Get-FWErrorKind $_.Exception.Message $_.FullyQualifiedErrorId) `
            -ErrorMessage $_.Exception.Message -Seconds $sw.Elapsed.TotalSeconds
    }
}

function Invoke-FWRemoteProbe {
    <#
    .SYNOPSIS
        Runs the probe on many machines in parallel over WinRM (Invoke-Command -AsJob).
    .DESCRIPTION
        Parallelism is bounded by ThrottleLimit. Each machine is a child job; a machine
        that fails is classified (Unreachable / AccessDenied / Timeout / Error) and never
        stops the others. Machines still running after TotalTimeoutSec are stopped and
        reported as Timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ComputerName,
        [Parameter(Mandatory)][hashtable]$Remote,
        [pscredential]$Credential
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $options = New-PSSessionOption -OpenTimeout ($Remote.openTimeoutSec * 1000) -OperationTimeout ($Remote.operationTimeoutSec * 1000)
    $params = @{
        ComputerName  = $ComputerName
        ScriptBlock   = (Get-FWProbe)
        ThrottleLimit = $Remote.throttleLimit
        SessionOption = $options
        AsJob         = $true
        ErrorAction   = 'Stop'
    }
    if ($Remote.useSsl) { $params.UseSSL = $true }
    if ($Credential) { $params.Credential = $Credential }

    try {
        $job = Invoke-Command @params
    } catch {
        $startError = $_
        $kind = Get-FWErrorKind $startError.Exception.Message $startError.FullyQualifiedErrorId
        return @($ComputerName | ForEach-Object { New-FWCollectionResult -ComputerName $_ -Reachability $kind -ErrorMessage $startError.Exception.Message })
    }

    try {
        [void](Wait-Job -Job $job -Timeout $Remote.totalTimeoutSec)
        $results = foreach ($child in $job.ChildJobs) {
            $name = $child.Location
            switch ($child.State) {
                'Completed' {
                    $out = @(Receive-Job -Job $child -ErrorAction SilentlyContinue -ErrorVariable recvErr)
                    if ($out.Count -gt 0) {
                        New-FWCollectionResult -ComputerName $name -Reachability 'Online' -Facts $out[-1] -Seconds $sw.Elapsed.TotalSeconds
                    } else {
                        $msg = if ($recvErr) { "$($recvErr[0])" } else { 'No data returned' }
                        New-FWCollectionResult -ComputerName $name -Reachability (Get-FWErrorKind $msg) -ErrorMessage $msg -Seconds $sw.Elapsed.TotalSeconds
                    }
                }
                'Failed' {
                    $reason = $child.JobStateInfo.Reason
                    $msg = if ($reason) { $reason.Message } else { 'Remote job failed' }
                    $errId = if ($reason -is [System.Management.Automation.Remoting.PSRemotingTransportException]) { "$($reason.ErrorCode)" } else { '' }
                    New-FWCollectionResult -ComputerName $name -Reachability (Get-FWErrorKind $msg $errId) -ErrorMessage $msg -Seconds $sw.Elapsed.TotalSeconds
                }
                default {
                    Stop-Job -Job $child
                    New-FWCollectionResult -ComputerName $name -Reachability 'Timeout' -ErrorMessage "No answer within $($Remote.totalTimeoutSec)s" -Seconds $sw.Elapsed.TotalSeconds
                }
            }
        }
        @($results)
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-FWCollection {
    <# Collects facts from every machine: Local ones in-process, Remote ones in one parallel batch. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Machines,
        [Parameter(Mandatory)][hashtable]$Config,
        [pscredential]$Credential
    )
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Machines | Where-Object Transport -EQ 'Local')) {
        $results.Add((Invoke-FWLocalProbe -ComputerName $m.ComputerName))
    }
    $remote = @($Machines | Where-Object Transport -EQ 'Remote' | ForEach-Object ComputerName)
    if ($remote.Count) {
        foreach ($r in @(Invoke-FWRemoteProbe -ComputerName $remote -Remote $Config.remote -Credential $Credential)) { $results.Add($r) }
        # Invoke-Command may report a machine under a different case/FQDN; make sure none is lost.
        foreach ($name in $remote) {
            if (-not ($results | Where-Object { $_.ComputerName -ieq $name })) {
                $results.Add((New-FWCollectionResult -ComputerName $name -Reachability 'Error' -ErrorMessage 'No result returned by the remoting layer'))
            }
        }
    }
    , $results.ToArray()
}
