# Operations runbook

## Every week (5 minutes)
1. Read the webhook message. If none came, check whether that is quiet mode (all OK and nothing changed) or a problem: see `reports\fleetwu.log`, where every run writes one line, including why the webhook was skipped or failed.
2. Open `reports\latest.html`. Start with **Changes since the previous run** (new problems and things that got worse), then the machine table.
3. Fix at the root cause, on the machine or in Group Policy. **FleetWU never changes settings**, so every fix is a deliberate change by a person.

## Finding → action

| Finding | Usual cause | Action |
|---|---|---|
| UpdateServices ALERT | Service disabled by a "debloat" script or old tool | Restore the start type (`wuauserv` Manual, `UsoSvc` Automatic) and find what disabled it |
| AutomaticUpdates ALERT `NoAutoUpdate=1` | Leftover GPO or registry tweak | Remove it from the GPO (`gpresult /h` on the machine shows which one) |
| AutomaticUpdates WARNING `AUOptions 2/3/5/7` | Policy asks for manual installs | Confirm the choice was intended, or set 4 |
| UpdatePause | Someone paused updates in Settings | Ask the user; resume in Settings → Windows Update |
| Deferral | WUfB deferral too long | Align with the policy (quality ≤ 7 days) |
| UpdateSource WARNING | Machine points at an unknown WSUS | Fix the GPO, or add the server to `approvedWsusServers` if it is legitimate |
| UpdateSource ALERT | Online update blocked and no WSUS | Fix urgently: the machine cannot get updates |
| LastQualityUpdate | Updates failing or machine rarely online | Check RecentFailures; run Windows Update on the machine |
| RecentFailures | Failing KB (error code shown) | Search the HRESULT; Windows Update troubleshooter; DISM / SFC |
| PendingReboot ALERT | Restart postponed for a week or more | Agree a restart time with the user |
| Connectivity WARNING | Machine off, travelling, asleep | Nothing, unless it repeats |
| Connectivity ALERT (3 runs) | Off for 3 weeks, WinRM broken, renamed, retired | Check the machine. If retired, set `Enabled=false` in the inventory |
| AccessDenied | Monitoring account not in the target's admin group | Fix the group membership (GPO Restricted Groups) |
| ProbeError (partial data) | One section could not be read | Run the tool against that machine and check the detail |

## When the run itself fails (exit 3 / `FAILED` in fleetwu.log)

| Message | Fix |
|---|---|
| `Inventory file not found` / `Duplicate ComputerName` / `Invalid ComputerName` | Fix `inventory.csv` |
| `Invalid configuration: …` | Fix `fleetwu.config.json`. The message names the setting |
| `Credential file not found` | Recreate it as the task account (INSTALL step 5) |
| `The inventory selection is empty` | Check the `-Group` / `-Tag` filters and the `Enabled` column |

## Webhook failed
`fleetwu.log` shows `webhook=FAILED: HTTP 4xx…`. A 4xx is not retried. Typical causes: the Teams workflow was deleted or the URL changed. Recreate it and update the `FLEETWU_WEBHOOK_URL` machine variable. The reports are still written, so nothing is lost.

## Files

| Path | Kept |
|---|---|
| `reports\latest.html / .csv / .json` | Overwritten each run |
| `reports\history\run-<id>.*` | Newest 26 runs (`report.keepRuns`) |
| `reports\fleetwu.log` | One line per run, never pruned (small) |

## Adding or removing machines
Edit `inventory.csv`; the next run picks it up. The trend section lists *added* and *removed* machines, so a deletion by mistake shows up.
