# Changelog

## [1.0.0] - 2026-11-26
- Agentless fleet monitor: inventory (CSV/JSON, groups, tags), Local + parallel WinRM transport with timeouts, unreachable / access denied / timeout classified per machine.
- 8 read-only Windows Update checks with configurable thresholds; connectivity streak escalation.
- Reports: HTML dashboard, CSV, JSON, console; history with retention; trend vs previous run.
- Webhook: Teams Adaptive Card, Slack, generic JSON; retries with back-off and Retry-After; quiet mode.
- Scheduled task register/unregister with pre-flight and -WhatIf; exit codes 0/1/2/3; run log.
- 131 Pester tests (PS 5.1 + 7 in CI), static read-only proof, mutation checks, PSScriptAnalyzer clean.
