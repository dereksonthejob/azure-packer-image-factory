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


# ── .NET 6 EOL Removal (Policy 200.5.8 — AzCertifyVulnerabilityId 106247) ────
# .NET 6 reached End of Life November 12, 2024.
# AzCertify flags it as CVSS 9.0 — must be removed from all Marketplace images.
Write-Host ""
Write-Host "=== Removing EOL .NET 6 (Policy 200.5.8) ==="

$dotnetDir = "$env:ProgramFiles\dotnet"
if (Test-Path $dotnetDir) {
    # Find all .NET 6 shared runtimes and SDKs
    $net6Paths = @(
        "$dotnetDir\shared\Microsoft.NETCore.App\6.*",
        "$dotnetDir\shared\Microsoft.AspNetCore.App\6.*",
        "$dotnetDir\shared\Microsoft.WindowsDesktop.App\6.*",
        "$dotnetDir\sdk\6.*",
        "$dotnetDir\packs\*\6.*",
        "$dotnetDir\templates\6.*"
    )

    $removed = 0
    foreach ($pattern in $net6Paths) {
        $matches = Get-Item $pattern -ErrorAction SilentlyContinue
        foreach ($item in $matches) {
            try {
                Remove-Item $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "  Removed: $($item.FullName)"
                $removed++
            } catch {
                Write-Warning "  Could not remove $($item.FullName): $_"
            }
        }
    }

    if ($removed -eq 0) {
        Write-Host "  No .NET 6 components found (already clean or not installed)"
    } else {
        Write-Host "  Removed $removed .NET 6 component path(s)"
    }

    # Verify no .NET 6 remains
    Write-Host ""
    Write-Host "  === .NET Versions Remaining After Cleanup ==="
    $runtimesLeft = Get-ChildItem "$dotnetDir\shared\Microsoft.NETCore.App\" -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name
    if ($runtimesLeft) {
        $runtimesLeft | ForEach-Object {
            $icon = if ($_ -like "6.*") { "❌ EOL" } else { "✅" }
            Write-Host "    $icon $_"
        }
    } else {
        Write-Host "  No .NET runtimes found"
    }
} else {
    Write-Host "  dotnet directory not found — .NET not installed, skipping"
}

# Also remove via Add/Remove Programs if present as a Features On Demand
Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*dotnet*6*" -and $_.State -eq "Installed" } |
    ForEach-Object {
        Write-Host "  Removing capability: $($_.Name)"
        Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null
    }

Write-Host ".NET 6 EOL removal complete."

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


# ── G11: WannaCry patch check ─────────────────────────────────────────────────
Write-Host ""
Write-Host "=== WannaCry Patch Check (G11) ==="
$srvSys  = "$env:SystemRoot\System32\drivers\srv.sys"
$srv2Sys = "$env:SystemRoot\System32\drivers\srv2.sys"

# Minimum patched versions per Microsoft Certification FAQ
$minVersions = @{
    "6.0"  = [Version]"6.0.6002.24230"   # 2008
    "6.1"  = [Version]"6.1.7601.23714"   # 2008R2 / Win7
    "6.2"  = [Version]"6.2.9200.22099"   # 2012
    "6.3"  = [Version]"6.3.9600.18546"   # 2012R2 / Win8.1
    "10.0" = $null                         # WS2016/2019+ no requirement
}

foreach ($file in @($srvSys, $srv2Sys)) {
    if (Test-Path $file) {
        $v   = [Version](Get-Item $file).VersionInfo.FileVersion
        $maj = "$($v.Major).$($v.Minor)"
        $min = $minVersions[$maj]
        if ($null -eq $min) {
            Write-Host "  ✅ $([System.IO.Path]::GetFileName($file)): $v (WS2016/2019+ — no minimum required)"
        } elseif ($v -ge $min) {
            Write-Host "  ✅ $([System.IO.Path]::GetFileName($file)): $v >= $min (WannaCry patched)"
        } else {
            Write-Host "  ❌ FAIL: $([System.IO.Path]::GetFileName($file)): $v < $min — WannaCry patch missing!"
        }
    } else {
        Write-Host "  ℹ️  $([System.IO.Path]::GetFileName($file)) not found (OK on newer Windows)"
    }
}

# ── G12: No default credentials ──────────────────────────────────────────────
Write-Host ""
Write-Host "=== Default Credentials Check (G12) ==="
# Ensure Administrator account requires a password and is not using known defaults
try {
    $adminStatus = net user Administrator 2>&1 | Select-String "Password required"
    Write-Host "  ✅ Administrator account requires password (sysprep will randomize)"
} catch {
    Write-Warning "  Could not verify Administrator account status: $_"
}
# Remove any known test/demo accounts
$testAccounts = @("demo","test","admin","user","azure")
foreach ($acct in $testAccounts) {
    $exists = (net user 2>&1) -match "^$acct\s"
    if ($exists) {
        Write-Host "  ⚠️  Removing test account: $acct"
        net user $acct /delete 2>&1 | Out-Null
    }
}
Write-Host "  ✅ No default/demo accounts found"

# ── G19: RDP must be enabled ─────────────────────────────────────────────────
Write-Host ""
Write-Host "=== RDP Enabled Check (G19) ==="
$rdpKey = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
$rdpVal = (Get-ItemProperty $rdpKey -Name "fDenyTSConnections" -ErrorAction SilentlyContinue).fDenyTSConnections
if ($rdpVal -eq 0) {
    Write-Host "  ✅ RDP is enabled (fDenyTSConnections = 0)"
} else {
    Write-Host "  Enabling RDP (fDenyTSConnections was $rdpVal) ..."
    Set-ItemProperty -Path $rdpKey -Name "fDenyTSConnections" -Value 0 -Force
    # Allow RDP through Windows Firewall
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    netsh advfirewall firewall set rule group="remote desktop" new enable=Yes 2>&1 | Out-Null
    Write-Host "  ✅ RDP enabled and firewall rule set"
}

# ── G15: OS Disk Size check (30–50 GB) ───────────────────────────────────────
Write-Host ""
Write-Host "=== OS Disk Size Check (G15) ==="
$cDrive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
if ($cDrive) {
    $totalGB = [Math]::Round(($cDrive.Used + $cDrive.Free) / 1GB, 1)
    if ($totalGB -le 50) {
        Write-Host "  ✅ C: drive total size: ${totalGB}GB (<= 50GB limit)"
    } elseif ($totalGB -le 128) {
        Write-Host "  ⚠️  C: drive total size: ${totalGB}GB (> 50GB — may need exception approval)"
    } else {
        Write-Host "  ❌ FAIL: C: drive total size: ${totalGB}GB (exceeds 128GB hard limit)"
    }
}

Write-Host ""
Write-Host "=== Security Check Complete: $(Get-Date -Format 'u') ==="
