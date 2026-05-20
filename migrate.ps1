<#
.SYNOPSIS
    Migrates endpoint security from CrowdStrike Falcon to Sophos.
    Designed for deployment as a Microsoft Intune Win32 app.

.DESCRIPTION
    The package folder must contain:
      - migrate.ps1   (this script)
      - config.json   (settings)
      - SophosSetup.exe  (or whatever filename is set in config.json)

    Workflow:
      1. Exit early if Sophos is already installed.
      2. Install Sophos silently using the command in config.json.
      3. Wait up to SophosTimeoutSeconds for a Sophos service to start.
      4. Exit with error if Sophos does not start in time (Falcon is left running).
      5. Uninstall CrowdStrike Falcon (GUID looked up from registry; flags from config.json).
      6. Wait up to CrowdStrikeTimeoutSeconds for Falcon to be fully removed.
      7. Exit with error if Falcon is not gone in time.
      8. Report the running Sophos process name and path.

    A transcript is written to %TEMP%\migrate-<timestamp>.log for troubleshooting.

.NOTES
    Requires Administrator or SYSTEM privileges.
    Tested on Windows 10/11 x64.
#>

#Requires -RunAsAdministrator

# Stop on terminating errors; non-terminating errors are handled explicitly.
$ErrorActionPreference = "Stop"

# Write a timestamped transcript to TEMP for post-hoc troubleshooting.
$transcriptPath = "$env:TEMP\migrate-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $transcriptPath -Append | Out-Null
Write-Host "Transcript: $transcriptPath"

# ============================================================
# Logging helper
# ============================================================

function Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
}

# ============================================================
# Load config.json
# ============================================================

$configPath = Join-Path $PSScriptRoot "config.json"
Log "Loading config from $configPath"

if (-not (Test-Path $configPath)) {
    Log "config.json not found at $configPath" "ERROR"
    Stop-Transcript | Out-Null
    exit 1
}

try {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
} catch {
    Log "Failed to parse config.json: $_" "ERROR"
    Stop-Transcript | Out-Null
    exit 1
}

Log "Config loaded. Sophos installer: $($cfg.SophosInstallerFileName) | Sophos timeout: $($cfg.SophosTimeoutSeconds)s | Falcon timeout: $($cfg.CrowdStrikeTimeoutSeconds)s"

# ============================================================
# Helper: return the first running Sophos service, or $null
# ============================================================

function Get-SophosService {
    Get-Service -DisplayName "Sophos*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq "Running" } |
        Select-Object -First 1
}

# ============================================================
# Helper: return the CrowdStrike/Falcon uninstall registry entry, or $null
# ============================================================

function Get-FalconRegistryEntry {
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $roots) {
        $entry = Get-ChildItem $root -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "CrowdStrike Sensor Platform" } |
            Select-Object -First 1
        if ($entry) { return $entry }
    }
    return $null
}

# ============================================================
# STEP 1 - Exit early if Sophos is already installed
# ============================================================

Log "--- Step 1: Checking if Sophos is already installed ---"

$existingSophos = Get-SophosService
if ($existingSophos) {
    Log "Sophos ('$($existingSophos.DisplayName)') is already running. Nothing to do." "WARN"
    Stop-Transcript | Out-Null
    exit 0
}

Log "Sophos is not installed. Proceeding."

# ============================================================
# STEP 2 - Install Sophos
# ============================================================

Log "--- Step 2: Installing Sophos ---"

$installerPath = Join-Path $PSScriptRoot $cfg.SophosInstallerFileName

if (-not (Test-Path $installerPath)) {
    Log "Sophos installer not found: $installerPath" "ERROR"
    Stop-Transcript | Out-Null
    exit 1
}

Log "Running: $installerPath $($cfg.SophosInstallArgs)"

try {
    $proc = Start-Process -FilePath $installerPath -ArgumentList $cfg.SophosInstallArgs -Wait -PassThru -ErrorAction Stop
    Log "Installer exited with code $($proc.ExitCode)"
} catch {
    Log "Failed to launch Sophos installer: $_" "ERROR"
    Stop-Transcript | Out-Null
    exit 1
}

# ============================================================
# STEP 3 - Wait for Sophos to be running
# STEP 4 - Exit with error on timeout (Falcon is left running)
# ============================================================

Log "--- Step 3: Waiting for Sophos service (timeout: $($cfg.SophosTimeoutSeconds)s) ---"

$sophosService = $null
$deadline      = (Get-Date).AddSeconds($cfg.SophosTimeoutSeconds)

while ((Get-Date) -lt $deadline) {
    $sophosService = Get-SophosService
    if ($sophosService) {
        Log "Sophos service '$($sophosService.DisplayName)' is Running."
        break
    }
    $remaining = [int]($deadline - (Get-Date)).TotalSeconds
    Log "Sophos not yet running. Retrying in 15s... ($remaining s remaining)"
    Start-Sleep -Seconds 15
}

if (-not $sophosService) {
    Log "Sophos did not start within $($cfg.SophosTimeoutSeconds)s. Aborting. CrowdStrike has NOT been removed." "ERROR"
    Stop-Transcript | Out-Null
    exit 1
}

# ============================================================
# STEP 5 - Uninstall CrowdStrike Falcon
# ============================================================

Log "--- Step 5: Uninstalling CrowdStrike Falcon ---"

$falconEntry = Get-FalconRegistryEntry

if (-not $falconEntry) {
    Log "Falcon not found in registry. It may already be removed." "WARN"
} else {
    Log "Found: $($falconEntry.DisplayName)"
    Log "UninstallString: $($falconEntry.UninstallString)"

    # Extract the product GUID from UninstallString.
    # Using the GUID from UninstallString (not the registry key name) avoids error 1605,
    # because this is the exact product code Windows Installer has on record.
    if ($falconEntry.UninstallString -imatch "(\{[A-F0-9-]{36}\})") {
        $guid = $matches[1]
    } else {
        Log "Could not find a product GUID in UninstallString: $($falconEntry.UninstallString)" "ERROR"
        Stop-Transcript | Out-Null
        exit 1
    }

    # On a 32-bit PowerShell process (which Intune may use), "msiexec.exe" resolves to
    # SysWOW64\msiexec.exe (32-bit), which returns error 1605 for 64-bit products like Falcon.
    # Sysnative is a virtual folder visible only to 32-bit processes that maps to the real System32.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $msiexec = "$env:SystemRoot\Sysnative\msiexec.exe"
    } else {
        $msiexec = "$env:SystemRoot\System32\msiexec.exe"
    }

    Log "Running: $msiexec /X $guid $($cfg.CrowdStrikeUninstallArgs)"

    try {
        $proc = Start-Process -FilePath $msiexec -ArgumentList "/X", $guid, $cfg.CrowdStrikeUninstallArgs -Wait -PassThru -ErrorAction Stop
        # 0 = success, 3010 = success with pending reboot
        if ($proc.ExitCode -notin @(0, 3010)) {
            Log "msiexec.exe exited with code $($proc.ExitCode)." "ERROR"
            Stop-Transcript | Out-Null
            exit 1
        }
        Log "Uninstall process completed (exit code $($proc.ExitCode))."
    } catch {
        Log "Failed to run msiexec.exe: $_" "ERROR"
        Stop-Transcript | Out-Null
        exit 1
    }
}

# ============================================================
# STEP 6 - Wait for Falcon to be fully removed
# STEP 7 - Exit with error on timeout
# ============================================================

Log "--- Step 6: Waiting for Falcon to be fully removed (timeout: $($cfg.CrowdStrikeTimeoutSeconds)s) ---"

$falconGone = $false
$deadline   = (Get-Date).AddSeconds($cfg.CrowdStrikeTimeoutSeconds)

while ((Get-Date) -lt $deadline) {
    $regEntry = Get-FalconRegistryEntry
    $svc      = Get-Service -Name "CSFalconService" -ErrorAction SilentlyContinue

    if (-not $regEntry -and (-not $svc -or $svc.Status -eq "Stopped")) {
        Log "Falcon registry entry and service are gone."
        $falconGone = $true
        break
    }

    $remaining = [int]($deadline - (Get-Date)).TotalSeconds
    if ($regEntry) { Log "Falcon still in registry. Waiting... ($remaining s remaining)" }
    if ($svc -and $svc.Status -ne "Stopped") { Log "CSFalconService is still '$($svc.Status)'. Waiting..." }
    Start-Sleep -Seconds 15
}

if (-not $falconGone) {
    Log "Falcon was not fully removed within $($cfg.CrowdStrikeTimeoutSeconds)s." "ERROR"
    Stop-Transcript | Out-Null
    exit 1
}

# ============================================================
# STEP 8 - Report running Sophos process
# ============================================================

Log "--- Step 8: Migration complete ---"

$sophosProcs = Get-Process | Where-Object { $_.Name -match "Sophos" }

if ($sophosProcs) {
    foreach ($p in $sophosProcs) {
        $path = try { $p.MainModule.FileName } catch { "(path restricted)" }
        Log "Sophos process: $($p.Name) | PID: $($p.Id) | Path: $path"
    }
} else {
    # Service is confirmed running even if no matching process name is visible
    Log "No Sophos process visible via Get-Process (access restriction), but service '$($sophosService.DisplayName)' is Running." "WARN"
}

Log "Done. Sophos is active. Falcon has been removed."
Stop-Transcript | Out-Null
exit 0
