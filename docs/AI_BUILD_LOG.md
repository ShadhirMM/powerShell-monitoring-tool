# AI build log

Built with **Claude Code** (Claude Opus 5.5). The rule: **AI writes, tests decide.**

| Step | AI output | How it was checked |
|---|---|---|
| Design | Agentless fleet monitor (one admin machine → many targets) rather than an agent per PC; read-only probe; WinRM batch with `Invoke-Command -AsJob -ThrottleLimit`; trend vs previous run | Mapped line by line to the job description (README table) |
| Probe | Self-contained read-only script block | Static allow-list test. Real run on the build machine: it read the services, policy, pause, reboot markers and real update history (last security update correctly found 13 days earlier) |
| Checks | 8 pure functions, thresholds in config | 31 named machine-state fixtures; JSON round-trip test (remoting deserialises objects) |
| Transport | Local + parallel remote, error classification | Mocked remoting; a **real** WinRM attempt to an unresolvable host (the build machine's WinRM service was left stopped and unchanged) |
| Reports, trend, webhook | HTML/CSV/JSON, retention, trend, Teams/Slack/generic payloads, retries | Pester tests including HTML injection, Retry-After, 4xx no-retry, quiet mode |
| Scheduling | Register/Unregister scripts with pre-flight | `-WhatIf` test (nothing registered); bad inventory refused before Task Scheduler is touched |

## Problems the checks caught
- **Real bug: PS 5.1 `$PSScriptRoot` quirk.** Windows PowerShell 5.1 leaves `$PSScriptRoot` empty while evaluating parameter defaults when a script is started with `powershell -File`, which is exactly how the scheduled task starts it. The entry script and the installer computed default paths that way. Running the test suite through `powershell -File` exposed it. Defaults now come from `$MyInvocation` in the script body, and a regression test runs the entry script with no `-OutputDir`.
- **Strict mode found a missing-column crash:** a minimal inventory CSV (only `ComputerName`) failed under `Set-StrictMode`. All optional columns are now read through one safe lookup, with a test for a one-column CSV.
- **Unrecognised timeout wording:** "cannot complete the operation within the time specified" was classified as `Error`. Fixed, with a test.
- **Variable shadowing:** in the remoting start-failure handler, `$_` inside `ForEach-Object` referred to the computer name, not the error. Fixed before first run.
- **PS 7 compatibility:** reading `Retry-After` differs between `WebHeaderCollection` (5.1) and `HttpResponseHeaders` (7); both are handled. `-UseBasicParsing` is passed only on 5.1.
- **Test bugs (not product bugs):** a scriptblock bound to the wrong positional parameter in a test helper (every "changed" fixture looked healthy, so 26 tests failed until it was found), a one-line log read as a string, and directories picked up by `-Include`.
- **A Python escape slip while editing** turned `\f` in a path into a form-feed character. A control-character scan of the repo found it, and it was fixed.

## Mutation checks
| Mutation | Result |
|---|---|
| `Set-ItemProperty …\AU NoAutoUpdate` planted in the probe | 2 read-only tests failed |
| Worst-status comparison inverted | 5 tests failed |
Both were restored, and the suite is green again.

## Not verified
| Item | Why | How to verify |
|---|---|---|
| Remote collection against real targets | No WinRM-enabled targets on the build machine (WinRM deliberately not enabled) | INSTALL step 3, then TEST_PLAN M01–M04 |
| Real scheduled-task registration | Only `-WhatIf` was run, to avoid changing the build PC | TEST_PLAN M06 |
| Teams/Slack rendering | Payloads tested as JSON; not posted to a real channel | TEST_PLAN M05 |
