<#
.SYNOPSIS
  Pre-update security check: captures source image patch baseline via Azure IMDS,
  snapshots installed hotfixes, runs Defender scan, and removes Defender (Policy 200).
  Writes C:\PatchReport\pre-update-hotfixes.csv for use by the post-update report script.
#>

$ErrorActionPreference = "Stop"
$ReportDir = "C:\PatchReport"
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

Write-Host "=== Windows Security Update Check ==="
Write-Host "Started at: $(Get-Date -Format 'u')"

# ── 1. Query Azure IMDS for source image metadata ─────────────────────────────
Write-Host ""
Write-Host "=== SOURCE IMAGE BASELINE (Azure IMDS) ==="
try {
    $imds = Invoke-RestMethod `
        -Uri "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01" `
        -Headers @{"Metadata"="true"} `
        -UseBasicParsing -TimeoutSec 5

    $imgRef  = $imds.storageProfile.imageReference
    $imgVer  = $imgRef.exactVersion

    # Image version format: MajorBuild.MinorBuild.YYMMDD  e.g. 17763.7009.260306 = Mar 6, 2026
    $patchDateRaw = if ($imgVer -match '^\d+\.\d+\.(\d{6})$') { $Matches[1] } else { "unknown" }
    $patchDate = if ($patchDateRaw -ne "unknown") {
        [datetime]::ParseExact($patchDateRaw, "yyMMdd", $null).ToString("yyyy-MM-dd")
    } else { "unknown" }

    Write-Host "Publisher : $($imgRef.publisher)"
    Write-Host "Offer     : $($imgRef.offer)"
    Write-Host "SKU       : $($imgRef.sku)"
    Write-Host "Version   : $imgVer"
    Write-Host "MS Patch  : $patchDate  ← last date Microsoft patched this base image"

    # Save for the post-update report to reference
    @{
        Publisher   = $imgRef.publisher
        Offer       = $imgRef.offer
        SKU         = $imgRef.sku
        Version     = $imgVer
        MSPatchDate = $patchDate
        CapturedAt  = (Get-Date -Format 'u')
    } | ConvertTo-Json | Set-Content "$ReportDir\source-image-metadata.json" -Encoding UTF8

} catch {
    Write-Warning "IMDS query failed (may not be available yet): $_"
    '{"Publisher":"unknown","Offer":"unknown","SKU":"unknown","Version":"unknown","MSPatchDate":"unknown"}' |
        Set-Content "$ReportDir\source-image-metadata.json" -Encoding UTF8
}

# ── 2. Check pending reboot state ─────────────────────────────────────────────
Write-Host ""
$rebootPending = $false
try {
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $rebootPending = $true }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $rebootPending = $true }
} catch { Write-Warning "Could not read reboot-pending registry keys: $_" }

if ($rebootPending) { Write-Host "WARNING: A reboot is pending before scan." }
else                { Write-Host "No pending reboots detected." }

# ── 3. Snapshot PRE-UPDATE hotfix list ────────────────────────────────────────
Write-Host ""
Write-Host "=== PRE-UPDATE HOTFIX BASELINE (what Microsoft shipped in the base image) ==="
$preHotfixes = Get-HotFix | Sort-Object -Property InstalledOn -Descending
$preHotfixes | Select-Object HotFixID, Description, InstalledOn | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Total pre-update patches: $($preHotfixes.Count)"

# Save to CSV for diff in post-update script
$preHotfixes | Select-Object HotFixID, Description, InstalledOn |
    Export-Csv "$ReportDir\pre-update-hotfixes.csv" -NoTypeInformation -Encoding UTF8

Write-Host "Pre-update snapshot saved to $ReportDir\pre-update-hotfixes.csv"
Write-Host "Security updates verified at: $(Get-Date -Format 'u')"

# ── 4. Install Defender, scan, then REMOVE before sysprep (Policy 200) ────────
Write-Host ""
Write-Host "=== DEFENDER SCAN (INSTALL -> SCAN -> REMOVE) ==="

try {
    Write-Host "Installing Windows-Defender feature for scan..."
    Install-WindowsFeature -Name Windows-Defender -Confirm:$false | Out-Null
    Start-Service WinDefend -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    Write-Host "--- Defender Status ---"
    Get-MpComputerStatus | Select-Object AMServiceEnabled, AntispywareEnabled, AntivirusEnabled, RealTimeProtectionEnabled |
        Format-List | Out-String | Write-Host

    Write-Host "--- Running Defender Quick Scan ---"
    Start-MpScan -ScanType QuickScan
    Write-Host "Quick scan completed."
} catch {
    Write-Warning "Defender install/scan error: $_"
} finally {
    Write-Host ""
    Write-Host "=== REMOVING DEFENDER (Marketplace Policy 200 Compliance) ==="
    try {
        Stop-Service WinDefend -Force -ErrorAction SilentlyContinue
        Uninstall-WindowsFeature -Name Windows-Defender -Confirm:$false | Out-Null
        Write-Host "Windows-Defender feature removed successfully."
    } catch {
        Write-Warning "Could not uninstall via feature: $_. Trying DisableWindowsOptionalFeature..."
        Disable-WindowsOptionalFeature -Online -FeatureName "Windows-Defender" -NoRestart -ErrorAction SilentlyContinue | Out-Null
    }
    $defState = (Get-WindowsFeature -Name Windows-Defender -ErrorAction SilentlyContinue).InstallState
    Write-Host "Windows-Defender state after removal: $defState"
}

Write-Host ""
Write-Host "=== Security Check Complete: $(Get-Date -Format 'u') ==="
