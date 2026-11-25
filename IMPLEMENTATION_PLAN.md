# PowerShell monitoring tool: implementation plan

> **Status: v1.0.0 code complete.** 131 tests pass locally (Windows PowerShell 5.1), and CI runs them on 5.1 and PowerShell 7. **Still to do with real infrastructure:** the manual tests M01–M08 (WinRM targets, a real Teams/Slack channel, real task registration) and screenshots.

**Brief:** a working script that checks Windows Update settings, produces status reports and sends alerts to a webhook.

**Design decision:** an **agentless fleet monitor**. One admin machine checks every machine over WinRM. This is different from a per-machine agent: there is one consolidated report, one message, and a week-to-week trend.

## Phases

| # | Phase | Done |
|---|---|---|
| 1 | Read-only probe (registry, services, WUA history, reboot markers) | ✅ real run on the build machine |
| 2 | Config + inventory with validation | ✅ |
| 3 | 8 checks, thresholds, worst-status rule | ✅ 31 fixtures |
| 4 | Transport: Local, parallel WinRM, error classification, timeouts | ✅ mocked + real unreachable host |
| 5 | Run model, connectivity streak, trend | ✅ |
| 6 | HTML / CSV / JSON, history retention | ✅ |
| 7 | Webhook payloads, retries, quiet mode | ✅ |
| 8 | Entry script, exit codes, run log, scheduled task + rollback | ✅ (`-WhatIf` only) |
| 9 | Static read-only proof, mutation checks, PSScriptAnalyzer, CI (5.1 + 7) | ✅ |
| 10 | Docs + samples | ✅ |
| 11 | Live verification M01–M08 | ⏳ needs WinRM-enabled targets |

## Mapping to the job description

| Job description | Where |
|---|---|
| "a PowerShell monitoring tool that checks Windows Update settings across machines" | Probe + 8 checks + parallel WinRM transport |
| "runs as a weekly scheduled task" | `install\Register-FleetWUTask.ps1` |
| "reports OK / WARNING / ALERT status to a webhook" | `Webhook.ps1`: Teams / Slack / generic |
| "without changing any settings" | `tests/ReadOnly.Tests.ps1` static proof + mutation check |
| "Package each program with its configuration, installation steps and documentation, test it before deployment" | config/, INSTALL.md, 131 tests in CI |
| "Follow change control … keep a tested rollback" | CHANGE_CONTROL.md, Unregister script |
| "Diagnose … build the evidence for escalation" | Findings carry the exact registry value, KB and HRESULT |
