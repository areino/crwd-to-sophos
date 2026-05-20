# Falcon to Sophos Migration — Intune Deployment Package

Silently migrates endpoint protection from CrowdStrike Falcon Sensor to Sophos on Windows 10/11 x64.
Designed to be deployed as a **Microsoft Intune Win32 app**.

---

## Package contents

| File | Purpose |
|---|---|
| `migrate.ps1` | Migration script |
| `config.json` | Settings (installer filename, install args, timeouts) |
| `SophosSetup.exe` | Sophos installer — obtain from your Sophos admin console |

All three files must be in the same folder. The script locates the installer and config relative to its own location (`$PSScriptRoot`).

---

## What the script does

1. **Checks Sophos is not already installed.** If a Sophos service is already running, the script exits cleanly without making any changes.
2. **Installs Sophos silently** using the installer filename and arguments from `config.json`.
3. **Waits for a Sophos service to start** (default: 10 minutes, polling every 15 seconds).
4. **Aborts if Sophos does not start in time** — Falcon is left running and the endpoint stays protected.
5. **Uninstalls CrowdStrike Falcon** via `msiexec`. The product GUID is read from the Windows registry at runtime so the script works across all Falcon Sensor versions without hardcoding. Silent flags are taken from `config.json`.
6. **Waits for Falcon to be fully removed** from the registry and services (default: 10 minutes).
7. **Aborts if Falcon is not gone in time** and logs an error.
8. **Reports all running Sophos processes** (name, PID, executable path) so the final state can be confirmed in logs.

The endpoint is **never left without protection**: Falcon is only removed after Sophos is confirmed running.

---

## config.json reference

```json
{
    "SophosInstallerFileName": "SophosSetup.exe",
    "SophosInstallArgs": "--quiet",
    "SophosTimeoutSeconds": 600,

    "CrowdStrikeUninstallArgs": "/qn /norestart",
    "CrowdStrikeTimeoutSeconds": 600
}
```

| Field | Description |
|---|---|
| `SophosInstallerFileName` | Filename of the Sophos installer in the package folder |
| `SophosInstallArgs` | Arguments passed to the Sophos installer. `--quiet` suppresses the UI. Add your Sophos registration token here if required by your product (e.g. `--quiet --token=XXXX`) |
| `SophosTimeoutSeconds` | Seconds to wait for a Sophos service to appear after install. Default: 600 (10 min) |
| `CrowdStrikeUninstallArgs` | Arguments appended to `msiexec /X {GUID}`. If your Falcon policy requires a maintenance token to allow uninstall, add it here: `/qn /norestart MAINTENANCE_TOKEN=your-token-here` |
| `CrowdStrikeTimeoutSeconds` | Seconds to wait for Falcon to disappear from the registry and services after uninstall. Default: 600 (10 min) |

---

## Deploying via Intune

### 1. Package the files

Create a `.intunewin` package from the scripts folder using the [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool):

```
IntuneWinAppUtil.exe -c .\scripts -s migrate.ps1 -o .\output
```

### 2. Create the Win32 app in Intune

| Setting | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File migrate.ps1` |
| Uninstall command | (not applicable — leave a no-op, e.g. `cmd /c exit 0`) |
| Install behavior | System |
| Device restart behavior | Determine behavior based on return codes |
| Return code 3010 | Soft reboot (Falcon removed, reboot pending) |

### 3. Detection rule

Use a **Registry** detection rule:

| Field | Value |
|---|---|
| Key path | `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` |
| Detection method | Key exists |

Or use a **Script** detection rule that checks for a running Sophos service and the absence of `CSFalconService`.

### 4. Assignments

Assign to a device group. Target the group containing endpoints that currently run Falcon and should be migrated.

---

## Logs and troubleshooting

Every run writes a timestamped transcript to:

```
C:\Users\<user>\AppData\Local\Temp\migrate-YYYYMMDD-HHmmss.log
```

When running as SYSTEM (Intune), the path is:

```
C:\Windows\Temp\migrate-YYYYMMDD-HHmmss.log
```

The log contains every step with timestamps and exit codes. Check this file first when troubleshooting a failed deployment.

### Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `Sophos installer not found` | `SophosInstallerFileName` in config does not match the actual filename in the package | Correct the filename in `config.json` |
| `Sophos did not start within Ns` | Installer ran but Sophos services did not come up | Increase `SophosTimeoutSeconds`; check Sophos install logs in `%TEMP%` |
| `msiexec exited with code 1605` | Script is running as 32-bit and resolved the wrong msiexec | The script handles this automatically via `Sysnative`; if still failing, verify Falcon is installed on the target machine |
| `msiexec exited with code 1603` | Falcon maintenance token required | Add `MAINTENANCE_TOKEN=your-token` to `CrowdStrikeUninstallArgs` in `config.json` |
| `Falcon was not fully removed within Ns` | Reboot required to complete driver removal | Increase `CrowdStrikeTimeoutSeconds` or handle return code 3010 as a soft reboot in Intune |
