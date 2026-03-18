<#
.SYNOPSIS
  AzCertify Pre-flight — re-images a PERSISTENT test VM with the new SIG image,
  runs Microsoft Certification Test Tool v1.6, and parses results.

.DESCRIPTION
  Uses a standing test VM (vm-certtest-windows / vm-certtest-linux) that is
  REUSED across builds — never deleted. After each successful packer build:
    1. Stop (deallocate) the persistent test VM
    2. Reimage it with the new SIG image version
    3. Start it and wait for connectivity
    4. Run CertificationTool.exe in CLI mode
    5. Parse XML results — exit 1 on FAIL/ERROR
    6. Leave VM running for the next build

.PARAMETER ImageResourceId
  Full ARM resource ID of the SIG image version.
  e.g. /subscriptions/.../galleries/.../images/.../versions/2026.03.18

.PARAMETER OSFamily
  'linux' or 'windows'

.PARAMETER CertVMRG
  Resource group containing the persistent test VM (default: RG-AZCERTIFY-PREFLIGHT)

.PARAMETER UseExistingVM
  Switch — if set, skip reimage and connect to the existing running VM.
  Used when debugging or running back-to-back tests on the same image.
#>
param(
    [Parameter(Mandatory=$true)]  [string] $ImageResourceId,
    [Parameter(Mandatory=$true)]  [ValidateSet("linux","windows")] [string] $OSFamily,
    [Parameter(Mandatory=$false)] [string] $CertVMRG   = "RG-AZCERTIFY-PREFLIGHT",
    [Parameter(Mandatory=$false)] [switch] $UseExistingVM
)

$ErrorActionPreference = "Stop"
$VMName    = "vm-certtest-$OSFamily-eastus"
$ToolDir   = "C:\CertificationTool"
$ToolExe   = "$ToolDir\CertificationTool.exe"
$ToolUrl   = "https://download.microsoft.com/download/B/0/7/B0745BE4-4BE2-4478-85FE-28C0B86A4C1E/Certification%20Test%20Tool%201.6%20for%20Azure%20Certified.msi"
$ReportXml = "azcertify-report.xml"
$SummaryMd = "azcertify-summary.md"
$AdminUser = "azurecertify"
$AdminPass = $env:CERTTEST_VM_PASSWORD   # Stored in GitHub secret, set once at bootstrap

Write-Host "================================================================"
Write-Host "  AzCertify Pre-flight (Persistent VM Mode)"
Write-Host "  VM:    $VMName  RG: $CertVMRG"
Write-Host "  Image: $ImageResourceId"
Write-Host "  OS:    $OSFamily"
Write-Host "================================================================"

if (-not $UseExistingVM) {
    # ── STOP VM ────────────────────────────────────────────────────────────────
    Write-Host "`n[1/5] Deallocating $VMName for reimage..."
    az vm deallocate --resource-group $CertVMRG --name $VMName --output none
    Write-Host "  Deallocated."

    # ── REIMAGE WITH NEW SIG IMAGE ────────────────────────────────────────────
    Write-Host "`n[2/5] Reimaging $VMName with $ImageResourceId"
    az vm update `
        --resource-group $CertVMRG `
        --name $VMName `
        --set "storageProfile.imageReference.id=$ImageResourceId" `
        --output none
    az vm reimage `
        --resource-group $CertVMRG `
        --name $VMName `
        --output none
    Write-Host "  Reimaged."

    # ── START VM ───────────────────────────────────────────────────────────────
    Write-Host "`n[3/5] Starting $VMName..."
    az vm start --resource-group $CertVMRG --name $VMName --output none
    Write-Host "  Started."
} else {
    Write-Host "`n[1-3/5] Skipped reimage — UseExistingVM flag set."
}

# Get public IP
$PublicIP = az vm show `
    --resource-group $CertVMRG `
    --name $VMName `
    --show-details `
    --query publicIps -o tsv
Write-Host "  Public IP: $PublicIP"

# Wait for connectivity
Write-Host "`n  Waiting for $OSFamily connectivity on $PublicIP..."
$port    = if ($OSFamily -eq "linux") { 22 } else { 3389 }
$timeout = 180; $elapsed = 0; $ready = $false
while ($elapsed -lt $timeout -and -not $ready) {
    Start-Sleep 10; $elapsed += 10
    $test  = Test-NetConnection -ComputerName $PublicIP -Port $port -WarningAction SilentlyContinue
    $ready = $test.TcpTestSucceeded
    Write-Host "  [$($elapsed)s] Ready=$ready"
}
if (-not $ready) { throw "VM $VMName not reachable after ${timeout}s on port $port" }

# ── INSTALL / CACHE CERTIFICATION TOOL ────────────────────────────────────────
Write-Host "`n[4/5] Certification Tool check..."
if (-not (Test-Path $ToolExe)) {
    Write-Host "  Downloading CertificationTool v1.6..."
    New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null
    Invoke-WebRequest -Uri $ToolUrl -OutFile "$ToolDir\certificationtool.msi" -UseBasicParsing
    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$ToolDir\certificationtool.msi`" /quiet INSTALLDIR=`"$ToolDir`""
    Write-Host "  Installed."
} else {
    Write-Host "  CertificationTool already installed (cached)."
}

# ── RUN CERTIFICATION TOOL ─────────────────────────────────────────────────────
Write-Host "`n  Running Certification Tool against $PublicIP ($OSFamily)..."
$certArgs = @(
    "/vm", $PublicIP,
    "/user", $AdminUser,
    "/password", $AdminPass,
    "/os", $OSFamily,
    "/reportlocation", $ReportXml
)
$proc = Start-Process -FilePath $ToolExe -ArgumentList $certArgs -Wait -PassThru -NoNewWindow
Write-Host "  Tool exited: $($proc.ExitCode)"

# ── PARSE RESULTS ──────────────────────────────────────────────────────────────
Write-Host "`n[5/5] Parsing $ReportXml..."
if (-not (Test-Path $ReportXml)) {
    Write-Error "No report XML found — tool may have failed to connect to $PublicIP"
    exit 1
}

[xml]$report = Get-Content $ReportXml
$failures = @(); $warnings = @(); $passes = @()
"# AzCertify Pre-flight Report`nImage: $ImageResourceId`n" | Set-Content $SummaryMd
"| Test | Result | Details |`n|------|--------|---------|" | Add-Content $SummaryMd

foreach ($r in $report.SelectNodes("//TestResult")) {
    $name   = $r.TestName ?? $r.Name ?? "Unknown"
    $result = ($r.Result ?? $r.Status ?? "UNKNOWN").ToUpper()
    $detail = ($r.Description ?? $r.Details ?? "") -replace "`n"," "
    "| $name | $result | $detail |" | Add-Content $SummaryMd
    switch ($result) {
        "FAILED"  { $failures += "$name`: $detail" }
        "ERROR"   { $failures += "ERROR — $name`: $detail" }
        "WARNING" { $warnings += $name }
        default   { $passes   += $name }
    }
}

Write-Host "  ✅ Passed:   $($passes.Count)"
Write-Host "  ⚠️  Warnings: $($warnings.Count)"
Write-Host "  ❌ Failures: $($failures.Count)"
if ($warnings) { $warnings | ForEach-Object { Write-Host "  ⚠️  $_" } }
if ($failures) {
    $failures | ForEach-Object { Write-Host "  ❌ $_" }
    Write-Host "`nAzCertify FAILED — block release until fixed."
    exit 1
}
Write-Host "`n✅ AzCertify PASSED — image is ready for Partner Center submission."
# VM stays running — reused on next build
