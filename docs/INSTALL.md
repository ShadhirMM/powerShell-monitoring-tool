# Installation

About 30 minutes, plus a Group Policy change if WinRM is not enabled on the targets yet.

## Requirements

| Where | What |
|---|---|
| Admin machine (runs the task) | Windows 10/11 or Server 2016+, Windows PowerShell 5.1 (built in) or PowerShell 7. No modules needed to run; Pester 5.5+ and PSScriptAnalyzer only for tests |
| Targets | Windows 10/11 or Server, **WinRM enabled** (PowerShell remoting), reachable on TCP 5985 (HTTP) or 5986 (HTTPS) from the admin machine |
| Account | A domain account that is a member of the targets' local **Administrators** group or **Remote Management Users** group (reading WUA history remotely needs admin rights on most builds) |

## 1. Copy the tool to the admin machine
```powershell
git clone https://github.com/ShadhirMM/powerShell-monitoring-tool.git C:\FleetWU
cd C:\FleetWU
Unblock-File -Path .\src\*.ps1, .\src\FleetWU\*, .\src\FleetWU\*\*, .\install\*.ps1   # if downloaded as a ZIP
```

## 2. First run: this machine only
```powershell
"ComputerName,Transport`nlocalhost,Local" | Set-Content .\config\inventory.csv
.\src\Start-FleetWUMonitor.ps1 -InventoryPath .\config\inventory.csv -NoWebhook
```
Open `reports\latest.html`. The exit code is the status (0/1/2).

## 3. Enable WinRM on the targets (Group Policy, documentation only)
Skip this if `Test-WSMan <target>` already answers. In the Group Policy Management Console, create a GPO linked to the OU with the target computers:

1. **Computer Configuration → Policies → Administrative Templates → Windows Components → Windows Remote Management (WinRM) → WinRM Service → Allow remote server management through WinRM**: *Enabled*. IPv4 filter: the admin machine's IP or subnet, not `*`.
2. **Computer Configuration → Policies → Windows Settings → Security Settings → System Services → Windows Remote Management (WS-Management)**: *Automatic*.
3. **Computer Configuration → Policies → Windows Settings → Security Settings → Windows Defender Firewall with Advanced Security → Inbound Rules → New rule → Predefined: Windows Remote Management**: allow, and scope it to the admin machine's IP.
4. Run `gpupdate /force` on a target (or wait), then from the admin machine: `Test-WSMan OFFICE-PC-01`.

Workgroup machines (no domain) need HTTPS listeners or `TrustedHosts` on the admin machine. Prefer HTTPS (`"useSsl": true` in the config).

## 4. The inventory
Copy `config\inventory.example.csv` to `config\inventory.csv` and list your machines:

| Column | Required | Meaning |
|---|---|---|
| ComputerName | yes | DNS name (letters, digits, `.`, `-`, `_`) |
| Group | no | e.g. Office, Residence. Use `-Group` to check one group |
| Tags | no | `;`-separated. Use `-Tag` to filter |
| Transport | no | `Local` for this machine, otherwise `Remote` (default) |
| Enabled | no | `false` keeps a row without checking it |

JSON works too (an array of the same fields, with `Tags` as an array).

## 5. Credentials (only if the task account is not already an admin on the targets)
Best: run the scheduled task **as** a dedicated monitoring account (step 7). Then no stored credential is needed.

Alternative: store a credential that only the task account on this machine can read (Windows DPAPI):
```powershell
# Run this AS the account that will run the task:
Get-Credential 'CORP\svc-fleetwu' | Export-Clixml C:\FleetWU\config\fleetwu.cred.xml
```
Set `"remote": { "credentialPath": "C:\\FleetWU\\config\\fleetwu.cred.xml" }` in the config. The file is git-ignored, and it cannot be decrypted by another user or on another machine.

## 6. Webhook
- **Teams:** in the channel, choose *Workflows → "Post to a channel when a webhook request is received"*, and copy the URL. Keep `"format": "teams"`.
- **Slack:** create an app → Incoming Webhooks → copy the URL, and set `"format": "slack"`.
- **Anything else:** `"format": "generic"` posts the JSON summary.

Store the URL as a **machine environment variable** (it is a secret, so not in the config file):
```powershell
[Environment]::SetEnvironmentVariable('FLEETWU_WEBHOOK_URL', '<url>', 'Machine')   # elevated prompt
```

## 7. Schedule it
```powershell
.\install\Register-FleetWUTask.ps1 -InventoryPath C:\FleetWU\config\inventory.csv -WhatIf     # preview + pre-flight
.\install\Register-FleetWUTask.ps1 -InventoryPath C:\FleetWU\config\inventory.csv -RunAsUser 'CORP\svc-fleetwu'
Start-ScheduledTask -TaskName 'FleetWU Windows Update fleet check'
Get-ScheduledTaskInfo -TaskName 'FleetWU Windows Update fleet check'   # LastTaskResult 0/1/2 = OK/WARNING/ALERT, 3 = run failed
```
Options: `-Day Friday -Time 16:00`, `-ConfigPath`, `-OutputDir`. Without `-RunAsUser`, the task runs only while the current user is logged on.

**Group Managed Service Account (gMSA):** register with `-WhatIf` to check the pre-flight, then create the task principal yourself: `New-ScheduledTaskPrincipal -UserId 'CORP\gmsa-fleetwu$' -LogonType Password`, and use `Set-ScheduledTask` to apply it to the task.

## Uninstall / roll back
```powershell
.\install\Unregister-FleetWUTask.ps1
```
Reports and history are kept. Delete `reports\` by hand if you no longer need it.
