<#
.SYNOPSIS
    Runs the Pester suite (Pester 5 or later) and PSScriptAnalyzer. Used locally and in CI.
.PARAMETER Output
    Folder for test-results.xml (NUnit) and the text summary.
#>
[CmdletBinding()]
param([string]$Output, [switch]$SkipAnalyzer)

$ErrorActionPreference = 'Stop'
if (-not $Output) { $Output = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\TestResults' }
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester 5.5 or later is required: Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck' }
Import-Module $pester.Path -Force
$null = New-Item -ItemType Directory -Path $Output -Force

$cfg = New-PesterConfiguration
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg.Run.Path = $here
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputFormat = 'NUnitXml'
$cfg.TestResult.OutputPath = Join-Path $Output 'test-results.xml'
$result = Invoke-Pester -Configuration $cfg

$analyzerIssues = 0
if (-not $SkipAnalyzer) {
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
        $root = Join-Path $here '..'
        # Shipped code only: the tests deliberately use fake credentials and fictional hard-coded machine names.
        $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
        $issues = @(foreach ($p in 'src', 'install') { Invoke-ScriptAnalyzer -Path (Join-Path $root $p) -Recurse -Settings $settings })
        $issues | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize | Out-String -Width 220 | Write-Output
        $analyzerIssues = $issues.Count
    } else { Write-Warning 'PSScriptAnalyzer not installed; analysis skipped.' }
}

$summary = "PowerShell $($PSVersionTable.PSVersion) | Pester $($pester.Version) | Passed: $($result.PassedCount) Failed: $($result.FailedCount) Skipped: $($result.SkippedCount) | PSScriptAnalyzer findings: $analyzerIssues"
$summary | Set-Content (Join-Path $Output "summary-ps$($PSVersionTable.PSVersion.Major).txt")
Write-Output $summary
if ($result.FailedCount -gt 0 -or $analyzerIssues -gt 0) { exit 1 }
exit 0
