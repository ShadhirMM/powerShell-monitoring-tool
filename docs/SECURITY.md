# Security

## Read-only by design (and proven)
- The probe that runs on each target uses only `Get-ItemProperty`, `Test-Path`, `Get-CimInstance` and the Windows Update Agent **history** query (`QueryHistory`). It never searches for, downloads or installs updates.
- `tests/ReadOnly.Tests.ps1` parses every source file and fails the build if any state-changing command appears (`Set-ItemProperty`, `Set-Service`, `Restart-Computer`, `Invoke-CimMethod`, `reg.exe`, `sc.exe`, `wuauclt`, `Start-Process`, `Invoke-Expression` …), or any registry-write or update-install method (`SetValue`, `CreateSubKey`, `Install`, `Download` …). The probe is also held to an **allow-list** of commands.
- A mutation check (a planted `Set-ItemProperty` in the probe) made the build fail, as intended.
- The only files the tool writes are in its own report folder.

## Least privilege
- Run the task as a **dedicated monitoring account** (or a gMSA), not as a personal admin account.
- That account needs remote access to the targets. Reading Windows Update history remotely usually needs local admin rights, so grant it on **workstations only**, through Group Policy (Restricted Groups), and nowhere else.
- The task runs with **Limited** run level, not "highest privileges".
- Limit WinRM by firewall scope and by the GPO IPv4 filter to the admin machine (INSTALL step 3).

## Credentials and secrets

| Secret | Where it lives | Never |
|---|---|---|
| Monitoring account password | Task Scheduler (when `-RunAsUser` is used), or a DPAPI-encrypted `Export-Clixml` file readable only by that account on that machine | In the config, the repo, or the scheduled-task arguments |
| Webhook URL | Machine environment variable `FLEETWU_WEBHOOK_URL` | In the config file or the repo |

`.gitignore` excludes `*.cred.xml`, `reports/`, `config/inventory.csv` and `TestResults/`.

## Transport
- Domain: WinRM over HTTP (5985) is encrypted by Kerberos at the message level.
- Workgroup or untrusted networks: use HTTPS listeners (`"useSsl": true`). Avoid `TrustedHosts = *`.
- The webhook is sent over HTTPS. The message contains machine names and findings, no credentials.

## Data in the reports
Machine names, OS build, update titles and error codes. Treat `reports\` as internal IT data: keep it on the admin machine or an IT-only share.

## Untrusted input
- Inventory names are validated against `^[A-Za-z0-9.\-_]{1,253}$` before they reach `Invoke-Command`.
- All machine data in the HTML is HTML-encoded. A test injects `<script>` through a registry value.
