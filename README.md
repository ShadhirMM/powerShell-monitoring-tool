# FleetWU: Windows Update settings monitor for a fleet

[![ci](https://github.com/ShadhirMM/powerShell-monitoring-tool/actions/workflows/ci.yml/badge.svg)](https://github.com/ShadhirMM/powerShell-monitoring-tool/actions/workflows/ci.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)
![License](https://img.shields.io/badge/license-MIT-blue)

A **read-only** PowerShell tool that runs on **one admin machine** and checks the Windows Update settings of **every machine in an inventory**. It does this in parallel over WinRM, writes an HTML dashboard plus CSV and JSON, shows **what changed since the last run**, and sends **one OK / WARNING / ALERT summary** to Microsoft Teams, Slack or any webhook. It runs weekly as a scheduled task and **never changes a setting**.

> Built as a portfolio project for an *IT Specialist (AI & Automation)* role. The job description includes *"a PowerShell monitoring tool that checks Windows Update settings across machines, runs as a weekly scheduled task and reports OK / WARNING / ALERT status to a webhook, without changing any settings."*

| Requirement | How it is met |
|---|---|
| Checks Windows Update settings | 8 checks per machine: update services, automatic-update policy, pause, deferrals, update source / WSUS, days since the last quality update, unresolved failed installs, pending reboot |
| …across machines | Inventory (CSV/JSON) with groups and tags. Local machine in-process, the others in parallel over WinRM (`Invoke-Command -AsJob -ThrottleLimit`), with timeouts. Unreachable / access denied / timeout machines are reported, never crash the run |
| Produces status reports | Self-contained HTML dashboard, CSV, JSON, console text; history with retention; **trend vs the previous run** (new, worse, resolved, still failing, machines added/removed) |
| Sends alerts to a webhook | One summary per run listing only WARNING/ALERT machines: Teams (Adaptive Card), Slack or generic JSON. Retries with back-off and `Retry-After`. Quiet when everything is OK |
| Weekly scheduled task | `install\Register-FleetWUTask.ps1` (pre-flight check, `-WhatIf`, rollback script). Exit code = status |
| Without changing any settings | Static AST test: no write command anywhere in `src`; the remote probe may only use an allow-list of read commands |

## Fleet monitor vs per-machine agent
A per-machine agent has to be installed on every PC and each one reports on its own. FleetWU is **agentless**: nothing is installed on the targets. One scheduled task on an admin machine reads every target over WinRM, so you get **one consolidated report and one message** for the whole fleet. Problems are compared week to week, and machines that are offline for several runs in a row escalate on their own.

## Sample (fictional machines)

```text
FleetWU run 20261125T060000Z: ALERT  (5 machines: 3 ALERT, 1 WARNING, 1 OK, 1 unreachable)
  ALERT   OFFICE-PC-01       Microsoft Windows 11 Pro 25H2 (build 26200.7171)
           [ALERT  ] AutomaticUpdates  Policy NoAutoUpdate=1: automatic updates are turned off
  ALERT   OFFICE-PC-02       Microsoft Windows 11 Pro 25H2 (build 26200.7171)
           [ALERT  ] UpdatePause       Updates paused until 2026-12-09 (14 days remaining)
           [WARNING] LastQualityUpdate 47 days ago on 2026-10-09: 2026-10 Cumulative Update for Windows 11 (KB5098001)
  ALERT   RES-MEDIA-01       Microsoft Windows 11 Pro 25H2 (build 26200.7171)
           [ALERT  ] PendingReboot     Reboot pending; last boot 9 days ago
  WARNING OFFICE-LT-03
           [WARNING] Connectivity      Unreachable: WinRM cannot complete the operation. (2 run(s) in a row)
  OK      RES-KIOSK-04       Microsoft Windows 11 Pro 25H2 (build 26200.7171)
  Since 20261118T060000Z: 2 new, 1 worse, 1 resolved, 2 still failing
```

Full samples: [HTML dashboard](docs/samples/report.html) · [CSV](docs/samples/report.csv) · [JSON](docs/samples/report.json) · webhook payloads: [Teams](docs/samples/payload-teams.json), [Slack](docs/samples/payload-slack.json), [generic](docs/samples/payload-generic.json)

## The checks

| Check | Reads | OK | WARNING | ALERT |
|---|---|---|---|---|
| UpdateServices | `wuauserv`, `UsoSvc`, `WaaSMedicSvc` start mode | enabled | WaaSMedicSvc disabled / unreadable | wuauserv or UsoSvc disabled or missing |
| AutomaticUpdates | `...\Policies\Microsoft\Windows\WindowsUpdate\AU` | no policy / `AUOptions=4` | `AUOptions` 2, 3, 5, 7, unknown | `NoAutoUpdate=1` |
| UpdatePause | `...\WindowsUpdate\UX\Settings` + policy pause dates | not paused | paused ≤ 7 days | paused > 7 days |
| Deferral | `DeferQualityUpdatesPeriodInDays`, `DeferFeatureUpdatesPeriodInDays` | quality < 8 d | quality 8–14 d, feature ≥ 181 d | quality ≥ 15 d |
| UpdateSource | `UseWUServer`, `WUServer`, `DoNotConnectToWindowsUpdateInternetLocations` | Microsoft Update or approved WSUS | WSUS not on the approved list | online blocked and no WSUS |
| LastQualityUpdate | Windows Update Agent history (`QueryHistory`), fallback `Win32_QuickFixEngineering` | ≤ 35 days | 36–60 days / none found | > 60 days |
| RecentFailures | failed installs in 30 days not fixed by a later success | none | 1–2 | ≥ 3 |
| PendingReboot | `RebootRequired`, CBS `RebootPending`, last boot | none | pending < 7 days uptime | pending ≥ 7 days uptime |
| Connectivity | WinRM result | online | unreachable / access denied / timeout | the same for 3 runs in a row |

Every threshold is in `config/fleetwu.config.json`. A machine's status is its worst check, and the fleet's status is its worst machine.

## Quick start

```powershell
# 1. Try it on this machine only (no WinRM needed)
"ComputerName,Transport`nlocalhost,Local" | Set-Content .\config\inventory.csv
.\src\Start-FleetWUMonitor.ps1 -InventoryPath .\config\inventory.csv -NoWebhook
start .\reports\latest.html

# 2. The fleet: list your machines (see config/inventory.example.csv), set the webhook, preview the task
$env:FLEETWU_WEBHOOK_URL = '<Teams Workflows / Slack webhook URL>'
.\install\Register-FleetWUTask.ps1 -InventoryPath .\config\inventory.csv -WhatIf
```
Full set-up, including enabling WinRM on the targets via Group Policy: [docs/INSTALL.md](docs/INSTALL.md).

Exit codes: `0` OK · `1` WARNING · `2` ALERT · `3` the run itself failed.

## Testing
**131 Pester tests**, run in GitHub Actions on Windows PowerShell 5.1 and PowerShell 7, plus PSScriptAnalyzer (0 findings on shipped code):
- 31 machine-state fixtures through every check
- mocked remoting (parallel batch, failures classified, missing results, credentials and timeouts passed through)
- **a real run on the build machine** through the Local transport
- a real WinRM attempt to an unresolvable host (reported, not fatal)
- reports, HTML escaping, retention, trend over several runs, unreachable streak escalation
- webhook payloads, retries, `Retry-After`, quiet mode
- exit codes in a child process, scheduled-task pre-flight with `-WhatIf`
- a **static read-only proof**

Mutation checks confirmed the tests catch a planted registry write and an inverted status rule. See [tests/TEST_PLAN.md](tests/TEST_PLAN.md).

```powershell
.\tests\Invoke-Tests.ps1     # Pester 5.5+ and PSScriptAnalyzer
```

## Repository
```
src/Start-FleetWUMonitor.ps1     entry point (scheduled task), exit codes, run log
src/FleetWU/                     module: Probe (read-only, runs on targets) · Transport · Checks · Report · Html · Webhook · Config · Inventory
config/                          fleetwu.config.json (thresholds, WSUS allow-list, remoting, webhook) · inventory.example.csv
install/                         Register / Unregister scheduled task
tests/                           Pester suite + fixtures, Invoke-Tests.ps1
tools/New-SampleReport.ps1       regenerates docs/samples from the fictional fleet
docs/                            INSTALL · OPERATIONS · CHANGE_CONTROL · SECURITY · AI_BUILD_LOG · samples/
```

## Limitations
- Needs WinRM (PowerShell remoting) on the targets for remote checks. Machines that are off or travelling show as unreachable, and escalate after 3 runs in a row.
- Policy values written by Intune/MDM under `PolicyManager` are not read yet (only Group Policy registry keys and Settings pauses).
- No OS end-of-servicing check (it needs a lifecycle table that must be kept up to date).

## How AI was used
Built with Claude Code. Every output was checked by tests, mutation checks and PSScriptAnalyzer. The tests found real problems, including a Windows PowerShell 5.1 `$PSScriptRoot` quirk that would have broken the scheduled task. See [docs/AI_BUILD_LOG.md](docs/AI_BUILD_LOG.md).

## License
MIT © Mushaff Shadhir
