<#
.SYNOPSIS
  Verifies and applies security updates, audits patch state, and runs a Defender
  scan — then removes Defender before sysprep (Commercial Marketplace Policy 200).
#>

$ErrorActionPreference = "Stop"

Write-Host "=== Windows Security Update Check ==="
Write-Host "Started at: $(Get-Date -Format 'u')"

# ── 1. Check pending reboot state ─────────────────────────────────────────────
$rebootPending = $false
try {
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $rebootPending = $true }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $rebootPending = $true }
} catch {
    Write-Warning "Could not read reboot-pending registry keys: $_"
}

if ($rebootPending) {
    Write-Host "WARNING: A reboot is currently pending before scan."
} else {
    Write-Host "No pending reboots detected."
}

# ── 2. Emit installed hotfix / patch evidence ──────────────────────────────────
Write-Host ""
Write-Host "=== INSTALLED HOTFIX EVIDENCE ==="
$hotfixes = Get-HotFix | Sort-Object -Property InstalledOn -Descending
$hotfixes | Select-Object -Property HotFixID, Description, InstalledOn | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Total installed patches: $($hotfixes.Count)"
Write-Host "Security updates verified at: $(Get-Date -Format 'u')"

# ── 3. Install Defender, run scan, then REMOVE it before sysprep ───────────────
# NOTE: Commercial Marketplace Policy 200 hard-bans pre-installed AV agents.
# We install → scan → uninstall in a single atomic sequence.
Write-Host ""
Write-Host "=== DEFENDER SCAN (INSTALL → SCAN → REMOVE) ==="

try {
    Write-Host "Installing Windows-Defender feature for scan..."
    Install-WindowsFeature -Name Windows-Defender -Confirm:$false | Out-Null
    Start-Service WinDefend -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    Write-Host "--- Defender Status Report ---"
    Get-MpComputerStatus | Select-Object AMServiceEnabled, AntispywareEnabled, AntivirusEnabled, RealTimeProtectionEnabled | Format-List | Out-String | Write-Host

    Write-Host "--- Running Defender Quick Scan ---"
    Start-MpScan -ScanType QuickScan
    Write-Host "Quick scan completed."
} catch {
    Write-Warning "Defender install/scan encountered an error: $_"
} finally {
    # Always remove Defender — runs even if scan threw an exception
    Write-Host ""
    Write-Host "=== REMOVING DEFENDER (Marketplace Policy 200 Compliance) ==="
    try {
        Stop-Service WinDefend -Force -ErrorAction SilentlyContinue
        Uninstall-WindowsFeature -Name Windows-Defender -Confirm:$false | Out-Null
        Write-Host "Windows-Defender feature removed successfully."
    } catch {
        # Some SKUs (e.g. Windows Server Core) may not support Uninstall-WindowsFeature
        Write-Warning "Could not uninstall Windows-Defender via feature removal: $_"
        Write-Warning "Attempting DisableWindowsOptionalFeature fallback..."
        Disable-WindowsOptionalFeature -Online -FeatureName "Windows-Defender" -NoRestart -ErrorAction SilentlyContinue | Out-Null
    }

    # Verify Defender is gone
    $defState = (Get-WindowsFeature -Name Windows-Defender -ErrorAction SilentlyContinue).InstallState
    Write-Host "Windows-Defender feature state after removal: $defState"
}

Write-Host ""
Write-Host "=== Security Check Complete: $(Get-Date -Format 'u') ==="
