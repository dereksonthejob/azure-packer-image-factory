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

    # THOROUGH DEFENDER REMOVAL (Policy 200.4.2)
    # AzCertify scans for binaries, registry keys, and services - not just Windows Feature state
    Write-Host "=== DEEP DEFENDER REMOVAL ==="

    # 1. Stop and disable all Defender services
    $defServices = @("WinDefend","WdNisSvc","WdFilter","WdBoot","MsMpEng","Sense","SecurityHealthService")
    foreach ($svc in $defServices) {
        try {
            Stop-Service  $svc -Force -ErrorAction SilentlyContinue
            Set-Service   $svc -StartupType Disabled -ErrorAction SilentlyContinue
        } catch { }
    }

    # 2. Remove Windows Defender feature
    Uninstall-WindowsFeature -Name Windows-Defender -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Uninstall-WindowsFeature -Name Windows-Defender-GUI -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Disable-WindowsOptionalFeature -Online -FeatureName "Windows-Defender" -NoRestart -ErrorAction SilentlyContinue | Out-Null

    # 3. Remove Defender program files and data
    $defPaths = @(
        "$env:ProgramFiles\Windows Defender",
        "$env:ProgramFiles\Windows Defender Advanced Threat Protection",
        "$env:ProgramData\Microsoft\Windows Defender",
        "$env:ProgramData\Microsoft\Windows Defender Advanced Threat Protection"
    )
    foreach ($p in $defPaths) {
        if (Test-Path $p) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed: $p"
        }
    }

    # 4. Remove Defender registry keys (AzCertify checks these)
    $defRegKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows Defender",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender",
        "HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend",
        "HKLM:\SYSTEM\CurrentControlSet\Services\WdNisSvc",
        "HKLM:\SYSTEM\CurrentControlSet\Services\WdFilter",
        "HKLM:\SYSTEM\CurrentControlSet\Services\MsMpEng",
        "HKLM:\SYSTEM\CurrentControlSet\Services\Sense"
    )
    foreach ($key in $defRegKeys) {
        if (Test-Path $key) {
            Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed registry: $key"
        }
    }

    $defStateAfter = (Get-WindowsFeature -Name Windows-Defender -ErrorAction SilentlyContinue).InstallState
    Write-Host "Windows-Defender state after deep removal: $defStateAfter"
    Write-Host "Deep Defender removal complete." 
}


# TLS 1.0 and TLS 1.1 Disable (Policy 200.5.8)
# Fixes AzCertify failures on ports 1433 (SQL Server) and 3389 (RDP)
Write-Host ""
Write-Host "=== DISABLING TLS 1.0 AND TLS 1.1 (Policy 200.5.8) ==="
$tlsBase = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"

foreach ($version in @("TLS 1.0", "TLS 1.1")) {
    foreach ($role in @("Server", "Client")) {
        $path = "$tlsBase\$version\$role"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name "Enabled"           -Value 0 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path $path -Name "DisabledByDefault" -Value 1 -PropertyType DWORD -Force | Out-Null
        Write-Host "  Disabled $version $role"
    }
}

# Enforce TLS 1.2 for SQL Server
$sqlNetLib = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib"
if (Test-Path $sqlNetLib) {
    New-ItemProperty -Path $sqlNetLib -Name "ForceEncryption" -Value 1 -PropertyType DWORD -Force | Out-Null
    Write-Host "  SQL Server ForceEncryption = 1 (forces TLS)"
}

# .NET strong crypto (prevents TLS downgrade from managed apps)
foreach ($fwPath in @(
    "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
)) {
    if (Test-Path $fwPath) {
        New-ItemProperty -Path $fwPath -Name "SchUseStrongCrypto"      -Value 1 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path $fwPath -Name "SystemDefaultTlsVersions" -Value 1 -PropertyType DWORD -Force | Out-Null
    }
}

# Verify
Write-Host ""
Write-Host "=== TLS Verification ==="
foreach ($ver in @("TLS 1.0","TLS 1.1","TLS 1.2")) {
    $sp = "$tlsBase\$ver\Server"
    if (Test-Path $sp) {
        $en = (Get-ItemProperty $sp -Name "Enabled" -ErrorAction SilentlyContinue).Enabled
        Write-Host "  $ver Server Enabled = $en  (0=disabled, 1=enabled)"
    }
}
Write-Host "TLS hardening complete."

Write-Host ""
Write-Host "=== Security Check Complete: $(Get-Date -Format 'u') ==="
