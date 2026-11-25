# Change control

Applies to the code, `fleetwu.config.json` (thresholds, WSUS allow-list), the inventory and the scheduled task.

1. **Scope.** Add an entry under *Unreleased* in `CHANGELOG.md`: what changes, why, the risk, and how to roll back.
2. **Test.**
   - `.\tests\Invoke-Tests.ps1`: all green, with 0 analyzer findings. A behaviour change gets a test that fails without it.
   - Threshold change: run once with `-NoWebhook` against the real fleet and compare `latest.json` with the previous run. The trend section shows exactly which findings appear or disappear because of the change.
3. **Deploy.** Copy the release to the admin machine (`git pull` or the tagged ZIP) and tag it `vX.Y.Z`. The task does not need re-registering unless the schedule, account or paths change.
4. **Verify.** `Start-ScheduledTask …`, then check `LastTaskResult`, `fleetwu.log` and the webhook message.
5. **Roll back.**
   - Code or config: `git checkout v<previous>` on the admin machine, then rerun step 4.
   - Task: `install\Unregister-FleetWUTask.ps1`, then re-register with the previous parameters.
   - Reports are never deleted by a rollback. History keeps the last 26 runs, so the trend survives.

## Record

| Date | Version | Change | Tests | Rollback tested |
|---|---|---|---|---|
| 2026-11-26 | 1.0.0 | First release | 131/131 (PS 5.1 local); CI PS 5.1 + 7 | Register `-WhatIf` pre-flight and Unregister no-op tested automatically; real register/unregister not yet run on the target admin machine |
