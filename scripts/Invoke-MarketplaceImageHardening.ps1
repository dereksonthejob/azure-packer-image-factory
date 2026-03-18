# Invoke-MarketplaceImageHardening.ps1
# Policy 200.4.2 — Defender ATP offboard + hardening for Azure Marketplace VM capture
# Policy 200.5.8 — Remove EOL .NET 6
# Include this script in ALL Windows Packer builds before sysprep.
# Source: azure-vm-offer-standards/scripts/Invoke-MarketplaceImageHardening.ps1

param(
    [switch]$SkipDefender,
    [switch]$SkipDotNet6Removal,
    [switch]$SkipVerification
)

$ErrorActionPreference = "Stop"
function Write-Section($msg) { Write-Output "`n=== $msg ===" }

# -------------------------------------------------------------------
# 1. POLICY 200.4.2 — Remove Microsoft Defender ATP
# -------------------------------------------------------------------
if (-not $SkipDefender) {
    Write-Section "Policy 200.4.2: Removing Microsoft Defender ATP"
    $services = @('WinDefend','WdNisSvc','MsSense','Sense','MpsSvc')
    foreach ($svc in $services) {
        if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
            Stop-Service  -Name $svc -Force        -ErrorAction SilentlyContinue
            Set-Service   -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Output "  Stopped + disabled: $svc"
        }
    }
    $mdeExe = 'C:\Program Files\Windows Defender Advanced Threat Protection\MsSense.exe'
    if (Test-Path $mdeExe) {
        Write-Output "  Running MDE uninstaller..."
        Start-Process -FilePath $mdeExe -ArgumentList 'uninstall' -Wait -ErrorAction SilentlyContinue
    }
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection',
        'HKLM:\SOFTWARE\Microsoft\Windows Defender\Spynet'
    )
    foreach ($rp in $regPaths) {
        if (Test-Path $rp) { Remove-Item -Path $rp -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "  Removed registry: $rp" }
    }
    $dirs = @(
        'C:\ProgramData\Microsoft\Windows Defender Advanced Threat Protection',
        'C:\Program Files\Windows Defender Advanced Threat Protection\Cyber',
        'C:\ProgramData\Microsoft\MDE'
    )
    foreach ($d in $dirs) {
        if (Test-Path $d) { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "  Removed: $d" }
    }
    if (-not $SkipVerification) {
        $remaining = Get-Process -Name 'MsSense','MsMpEng' -ErrorAction SilentlyContinue
        if ($remaining) { throw "CERTIFICATION BLOCKER (Policy 200.4.2): Defender still running: $($remaining.Name -join ', ')" }
    }
    Write-Output "  Defender ATP offboard: COMPLETE"
}

# -------------------------------------------------------------------
# 2. POLICY 200.5.8 — Remove EOL .NET 6 (AzCertifyVulnerabilityId: 106247)
# -------------------------------------------------------------------
if (-not $SkipDotNet6Removal) {
    Write-Section "Policy 200.5.8: Removing EOL .NET 6 (CVE AzCertify 106247)"
    $net6Paths = @(
        'C:\Program Files\dotnet\shared\Microsoft.NETCore.App\6.*',
        'C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App\6.*',
        'C:\Program Files\dotnet\shared\Microsoft.AspNetCore.App\6.*',
        'C:\Program Files\dotnet\host\fxr\6.*',
        'C:\Program Files\dotnet\sdk\6.*'
    )
    foreach ($p in $net6Paths) {
        if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "  Purged: $p" }
    }
    Write-Output "  .NET 6 removal: COMPLETE"
}

Write-Section "Marketplace image hardening complete — ready for sysprep"
