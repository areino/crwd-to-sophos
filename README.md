# Falcon to Sophos Migration — Intune Deployment Guide

Silently migrates endpoint protection from CrowdStrike Falcon Sensor to Sophos on Windows 10/11 x64.

---

## Table of contents

1. [How it works](#how-it-works)
2. [Package contents](#package-contents)
3. [Before you start](#before-you-start)
4. [Step 1 — Configure config.json](#step-1--configure-configjson)
5. [Step 2 — Build the .intunewin package](#step-2--build-the-intunewin-package)
6. [Step 3 — Create the Win32 app in Intune](#step-3--create-the-win32-app-in-intune)
7. [Step 4 — Assign to devices](#step-4--assign-to-devices)
8. [Step 5 — Monitor the rollout](#step-5--monitor-the-rollout)
9. [Logs and troubleshooting](#logs-and-troubleshooting)

---

## How it works

The script follows a strict order that ensures the endpoint is **never left without active protection**:

1. Check if Sophos is already running — exit cleanly if so (idempotent, safe to re-run).
2. Install Sophos silently.
3. Wait for a Sophos service to come up (up to `SophosTimeoutSeconds`).
4. **If Sophos does not start — abort.** Falcon is left running.
5. Uninstall CrowdStrike Falcon silently. The product GUID is read from the Windows registry at runtime, so the script works across all Falcon Sensor versions without any hardcoding.
6. Wait for Falcon to disappear from the registry and services (up to `CrowdStrikeTimeoutSeconds`).
7. **If Falcon does not disappear — log an error** and exit non-zero.
8. Report all running Sophos processes (name, PID, path) to confirm success.

A full timestamped transcript is written to disk on every run — see [Logs and troubleshooting](#logs-and-troubleshooting).

---

## Package contents

These three files must live in the same folder and be packaged together:

```
scripts/
  migrate.ps1      <- migration script (do not rename)
  config.json      <- settings you edit before packaging
  SophosSetup.exe  <- Sophos installer from your Sophos admin console
```

The script locates `config.json` and the installer relative to its own location, so the folder structure above must be preserved inside the `.intunewin` archive.

---

## Before you start

- **Sophos installer** — download `SophosSetup.exe` from your Sophos Central console:
  _Sophos Central > Devices > Installers > Download installer for Windows_.
  Place it in the `scripts/` folder alongside `migrate.ps1`.

- **Falcon maintenance token** (if required) — if your Falcon policy has _Sensor Tampering Protection_ enabled, uninstallation requires a maintenance token. Retrieve it from the Falcon console:
  _Host Management > select a host > Reveal Maintenance Token_.
  You will add this token to `config.json` in the next step.

- **Microsoft Win32 Content Prep Tool** — download from
  https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
  and place `IntuneWinAppUtil.exe` somewhere accessible (e.g. `C:\Tools\`).

- **Intune role** — you need the _Mobile Device Management / Apps_ role in Intune to create and assign apps.

---

## Step 1 — Configure config.json

Open `config.json` and edit the values for your environment before packaging.

```json
{
    "SophosInstallerFileName": "SophosSetup.exe",
    "SophosInstallArgs": "--quiet",
    "SophosTimeoutSeconds": 600,

    "CrowdStrikeUninstallArgs": "/qn /norestart",
    "CrowdStrikeTimeoutSeconds": 600
}
```

### Field reference

**`SophosInstallerFileName`**
The filename of the Sophos installer in the package folder.
Change this only if you renamed the installer file.
Default: `SophosSetup.exe`

**`SophosInstallArgs`**
Arguments passed to the Sophos installer executable.
`--quiet` suppresses the installer UI for silent deployment.
If your Sophos product requires a registration token (common for Sophos Central-managed installs), append it here:
```json
"SophosInstallArgs": "--quiet --token=XXXX-XXXX-XXXX-XXXX"
```
Check your Sophos documentation for the exact flag name — some versions use `--customerid` instead of `--token`.

**`SophosTimeoutSeconds`**
How long (in seconds) to wait for a Sophos service to appear after the installer finishes.
Sophos installs drivers and services that can take 3–5 minutes on a slow disk.
Increase this if deployments are timing out on older hardware.
Default: `600` (10 minutes)

**`CrowdStrikeUninstallArgs`**
Arguments appended to `msiexec /X {GUID}` when removing Falcon.
`/qn` = fully silent (no UI). `/norestart` = suppress automatic reboot.

If your Falcon policy has Sensor Tampering Protection enabled, add the maintenance token here:
```json
"CrowdStrikeUninstallArgs": "/qn /norestart MAINTENANCE_TOKEN=your-token-here"
```
Without the token, msiexec will return exit code **1603** and the uninstall will fail.

**`CrowdStrikeTimeoutSeconds`**
How long (in seconds) to wait for Falcon to disappear from the registry and services after the uninstall command completes.
Falcon's kernel driver removal may require a reboot on some versions — if you see timeouts here, consider increasing this value and handling return code 3010 in Intune as a soft reboot.
Default: `600` (10 minutes)

---

## Step 2 — Build the .intunewin package

Run the following from a command prompt, adjusting paths as needed:

```cmd
IntuneWinAppUtil.exe -c "C:\git\duck-tales\scripts" -s migrate.ps1 -o "C:\git\duck-tales\output"
```

| Flag | Meaning |
|---|---|
| `-c` | Source folder — the folder containing all three package files |
| `-s` | Setup file — the entry point Intune will reference (the script, not the installer) |
| `-o` | Output folder — where the `.intunewin` file will be written |

This produces `migrate.intunewin` in the output folder. That file is what you upload to Intune.

---

## Step 3 — Create the Win32 app in Intune

Go to **Intune admin center** (https://intune.microsoft.com) > **Apps** > **All apps** > **Add**.
Select app type: **Windows app (Win32)**, then click **Select**.

### App information

| Field | Value |
|---|---|
| App package file | Upload `migrate.intunewin` |
| Name | `Falcon to Sophos Migration` |
| Description | Silently installs Sophos and removes CrowdStrike Falcon Sensor |
| Publisher | Your organisation name |
| Category | `Computer Management` (optional, for end-user portal visibility) |
| Show this as a featured app | No |

Click **Next**.

---

### Program

| Field | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -NonInteractive -File migrate.ps1` |
| Uninstall command | `cmd.exe /c exit 0` |
| Install behavior | **System** |
| Device restart behavior | **Determine behavior based on return codes** |
| Return codes | See table below |

**Return codes** — verify or add these under the return codes section:

| Code | Type | Meaning |
|---|---|---|
| `0` | Success | Migration completed, no reboot needed |
| `3010` | Soft reboot | Migration completed, reboot pending (Falcon driver pending removal) |
| `1` | Failed | Script encountered an error — check logs |

Click **Next**.

---

### Requirements

| Field | Value |
|---|---|
| Operating system architecture | **64-bit** |
| Minimum operating system | **Windows 10 1903** or later |
| Disk space required (MB) | 500 (leave blank to skip) |
| Physical memory (MB) | (leave blank) |
| Minimum number of logical processors | (leave blank) |
| Minimum CPU speed (MHz) | (leave blank) |

> **Important — Run PowerShell as 64-bit**
> Scroll down within Requirements and expand **Additional requirement rules**. Add a script requirement:
>
> | Field | Value |
> |---|---|
> | Requirement type | Script |
> | Script | A one-liner that exits 0 (see below) |
> | Run script as 32-bit process on 64-bit clients | **No** |
> | Run this script using the logged on credentials | No (run as SYSTEM) |
>
> Alternatively, set **Run PowerShell script as 32-bit process** to **No** on the script deployment itself if you deploy `migrate.ps1` via the Intune PowerShell Scripts blade instead of Win32 app. The Win32 app method is preferred because it gives you return code control.

Click **Next**.

---

### Detection rules

Detection tells Intune whether the app is already installed. Use a **Custom script** rule for reliable detection:

| Field | Value |
|---|---|
| Rules format | **Use a custom detection script** |
| Script file | Create a file `detect.ps1` with the contents below |
| Run script as 32-bit process on 64-bit clients | **No** |
| Enforce script signature check | No |
| Run this script using the logged on credentials | No |

**detect.ps1** — the app is considered installed when Sophos is running AND Falcon is gone:

```powershell
$sophos = Get-Service -DisplayName "Sophos*" -ErrorAction SilentlyContinue |
              Where-Object { $_.Status -eq "Running" } |
              Select-Object -First 1

$falcon = Get-Service -Name "CSFalconService" -ErrorAction SilentlyContinue

if ($sophos -and (-not $falcon -or $falcon.Status -eq "Stopped")) {
    Write-Host "Detected"
    exit 0
}
exit 1
```

Intune treats exit code `0` as detected (installed) and any other exit code as not detected (needs install).

Click **Next**.

---

### Dependencies

No dependencies required. Click **Next**.

---

### Supersedence

If you have a previous version of this migration app, add it here so Intune replaces it. Otherwise leave empty. Click **Next**.

---

### Assignments

See [Step 4](#step-4--assign-to-devices) below. Click **Next**, review, then **Create**.

---

## Step 4 — Assign to devices

On the Assignments tab (or edit the app after creation):

### Recommended approach — staged rollout

| Group | Assignment type | Purpose |
|---|---|---|
| `Migration-Pilot` (10–20 devices) | Required | Validate on a small set first |
| `Migration-Wave-1` | Required | First production wave after pilot passes |
| `Migration-All` | Required | All remaining target devices |

Use **Filters** to target only devices that actually have Falcon installed, avoiding unnecessary runs on devices that were never enrolled in Falcon.

### Assignment settings per group

When adding a group, click the group row to expand assignment settings:

| Setting | Value |
|---|---|
| App notification | **Hide all toast notifications** (silent deployment) |
| Installation deadline | Set a date/time for forced install if needed |
| Grace period | 0 (install immediately, or set to e.g. 1440 min to delay until next day) |
| Restart grace period | 120 minutes (gives users time before a pending reboot is forced) |

---

## Step 5 — Monitor the rollout

Go to **Intune admin center > Apps > All apps > Falcon to Sophos Migration > Device install status**.

| Column | What to check |
|---|---|
| Install status | `Installed` = success, `Failed` = check error code |
| Error code | `0` = success, `3010` = needs reboot, `1` = script error |
| Last modified | Confirms when Intune last attempted the install |

For devices showing **Failed**:
1. Note the error code from the Device install status view.
2. Collect the transcript log from the device — see below.
3. Re-run by going to the device in Intune > **Sync**, which forces a re-check.

---

## Logs and troubleshooting

### Transcript log

Every run writes a full timestamped log to:

```
C:\Windows\Temp\migrate-YYYYMMDD-HHmmss.log
```

_(When running as SYSTEM via Intune, `%TEMP%` resolves to `C:\Windows\Temp`)_

The log contains every step, the exact commands run, and all exit codes. This is the first place to look for any failure.

Collect the log remotely via Intune: **Devices > select device > Collect diagnostics** (requires Diagnostics collection enabled in your tenant), or use a Live Response / remote shell session.

### Common failures

| Error / symptom | Cause | Fix |
|---|---|---|
| `config.json not found` | The `.intunewin` package was built from the wrong folder, or `config.json` was not included | Rebuild the package from the `scripts/` folder that contains all three files |
| `Sophos installer not found` | `SophosInstallerFileName` in `config.json` does not match the actual filename | Correct the filename, rebuild, and redeploy |
| `Sophos did not start within Ns` | Installer ran but Sophos services did not come up in time | Increase `SophosTimeoutSeconds`; check `%TEMP%\Sophos*.log` on the device for Sophos-side errors |
| msiexec exit code `1605` | 32-bit msiexec was used and cannot see 64-bit Falcon product | Ensure **Run as 32-bit process** is set to **No** in Intune; the script includes a Sysnative fallback but the Intune setting overrides it |
| msiexec exit code `1603` | Falcon Sensor Tampering Protection is enabled and no maintenance token was provided | Add `MAINTENANCE_TOKEN=your-token-here` to `CrowdStrikeUninstallArgs` in `config.json` |
| msiexec exit code `1618` | Another MSI installation is already in progress on the device | Intune will retry; if persistent, check for stuck Windows Update or other deployment |
| `Falcon was not fully removed within Ns` | Falcon driver removal requires a reboot to complete | Allow Intune to process the `3010` return code as a soft reboot; increase `CrowdStrikeTimeoutSeconds` as a short-term workaround |
| Detection rule keeps triggering reinstall | `detect.ps1` is not returning exit 0 | Run `detect.ps1` manually on the device as SYSTEM (use PsExec: `psexec -s powershell`) and check its output |
