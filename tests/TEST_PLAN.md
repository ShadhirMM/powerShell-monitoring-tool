# Test plan

## Automated: `.\tests\Invoke-Tests.ps1`
CI: GitHub Actions `windows-latest`, Windows PowerShell 5.1 **and** PowerShell 7. Results: `TestResults/` (NUnit XML + summary).

| File | Tests | Covers |
|---|---|---|
| Checks.Tests.ps1 | 38 | 31 machine-state fixtures (one per OK/WARNING/ALERT branch of all 8 checks), healthy machine, JSON round trip, a throwing check becomes WARNING, thresholds from config, pause detail text, worst status, date parsing |
| ConfigInventory.Tests.ps1 | 19 | Defaults and shipped config valid; partial override; 7 invalid-config cases; missing/invalid JSON; example inventory; group/tag filters; JSON inventory; minimal CSV; 4 invalid-inventory cases; wrong file type |
| Transport.Tests.ps1 | 13 | Error classification (5 cases), message shortening; Local vs one Remote batch; lost result reported; Invoke-Command start failure; local probe failure; credential, throttle and timeouts passed through; **real local probe**; **real WinRM attempt to an unresolvable host** |
| Report.Tests.ps1 | 10 | Counts, sorting, run id; 9 checks per online machine; unreachable streak → ALERT at 3, reset when back; probe partial errors; trend: first run, new/worse/resolved/added/removed, still failing; files + retention + CSV + previous run; unreadable history; HTML self-contained and escaped |
| Webhook.Tests.ps1 | 11 | Teams/Slack/generic payloads valid and listing only problem machines; Adaptive Card; generic findings; cap and "N more"; quiet mode; delivery success, 5xx + network retry delays, Retry-After, 4xx no retry, give up after retries |
| EndToEnd.Tests.ps1 | 12 | Two runs with trend and webhook; quiet mode; missing URL; failed webhook doesn't fail the run; empty selection; **real run on this machine**; exit codes 0/1/2 and 3 in a child process; default output folder under `powershell -File`; Register `-WhatIf` pre-flight; bad inventory refused; Unregister no-op |
| ReadOnly.Tests.ps1 | 28 | Per source file: no state-changing command, no registry-write or install method; probe allow-list; history query only; registry paths only in the probe; deletes only in the history folder |
| **Total** | **131** | Latest local run: Windows PowerShell 5.1, Pester 6.2.0: 131 passed, 0 failed; PSScriptAnalyzer: 0 findings |

## Manual (before go-live, with screenshots)

| ID | Test | Pass when |
|---|---|---|
| M01 | `Test-WSMan` from the admin machine to two targets | Both answer |
| M02 | Run with 2 reachable targets + 1 switched-off target | 2 Online with 9 checks; 1 Unreachable WARNING; HTML opens |
| M03 | Target where the account is not admin | `AccessDenied` reported, other machines fine |
| M04 | Pause updates on one target, run again | Trend shows *New problem: UpdatePause*; resume → *Resolved* next run |
| M05 | Real Teams Workflows URL and a Slack webhook | Card/message renders; only problem machines listed |
| M06 | `Register-FleetWUTask.ps1` for real, `Start-ScheduledTask` | `LastTaskResult` equals the status code; `fleetwu.log` line written |
| M07 | `Unregister-FleetWUTask.ps1` | Task gone; reports kept |
| M08 | Compare the target's registry before and after a run (`reg export` of the WindowsUpdate keys) | Identical: nothing changed |
