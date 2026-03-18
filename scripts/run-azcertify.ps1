<#
.SYNOPSIS
  AzCertify Pre-flight — deploys test VM from SIG, runs Microsoft Certification
  Test Tool v1.6, parses results, and cleans up.

.DESCRIPTION
  This script is called by the azcertify-validation.yml GitHub Actions workflow
  after a successful Packer build. It:
    1. Deploys a temporary test VM from the Shared Image Gallery (SIG)
    2. Downloads and installs the Certification Test Tool v1.6
    3. Runs the tool in CLI mode against the test VM
    4. Parses the XML report — fails with exit code 1 if any FAIL/ERROR
    5. Always deletes the test VM in the finally block

.PARAMETER ImageResourceId
  Full resource ID of the SIG image version to test.
  e.g. /subscriptions/.../galleries/.../images/.../versions/2026.03.18

.PARAMETER OSFamily
  'linux' or 'windows'

.PARAMETER VMSize
  VM size for the test VM (default: Standard_D4s_v4)

.PARAMETER Location
  Azure region (default: eastus)
#>
param(
    [Parameter(Mandatory=$true)]  [string] $ImageResourceId,
    [Parameter(Mandatory=$true)]  [ValidateSet("linux","windows")] [string] $OSFamily,
    [Parameter(Mandatory=$false)] [string] $VMSize     = "Standard_D4s_v4",
    [Parameter(Mandatory=$false)] [string] $Location   = "eastus",
    [Parameter(Mandatory=$false)] [string] $ResourceGroup = "RG-AZCERTIFY-PREFLIGHT-TMP"
)

$ErrorActionPreference = "Stop"
$RunId   = [System.Environment]::GetEnvironmentVariable("GITHUB_RUN_ID") ?? (Get-Date -Format "yyyyMMddHHmmss")
$VMName  = "azcertify-$($OSFamily)-$RunId"
$AdminUser = "azurecertify"
# Random password: 16 chars, meets complexity
Add-Type -AssemblyName System.Web
$AdminPass = [System.Web.Security.Membership]::GeneratePassword(16, 4)

$ToolUrl  = "https://download.microsoft.com/download/B/0/7/B0745BE4-4BE2-4478-85FE-28C0B86A4C1E/Certification%20Test%20Tool%201.6%20for%20Azure%20Certified.msi"
$ToolDir  = "C:\CertificationTool"
$ToolExe  = "$ToolDir\CertificationTool.exe"
$ReportXml = "azcertify-report.xml"
$SummaryMd = "azcertify-summary.md"

Write-Host "================================================================"
Write-Host "  AzCertify Pre-flight"
Write-Host "  Image:   $ImageResourceId"
Write-Host "  OS:      $OSFamily"
Write-Host "  VM Size: $VMSize"
Write-Host "  Run ID:  $RunId"
Write-Host "================================================================"

# Ensure test resource group exists
Write-Host "`n[1/5] Ensuring test resource group: $ResourceGroup"
az group create --name $ResourceGroup --location $Location --output none

try {
    # ── DEPLOY TEST VM ────────────────────────────────────────────────────────
    Write-Host "`n[2/5] Deploying test VM: $VMName"
    $vmOutput = az vm create `
        --resource-group $ResourceGroup `
        --name $VMName `
        --image $ImageResourceId `
        --size $VMSize `
        --admin-username $AdminUser `
        --admin-password $AdminPass `
        --public-ip-address "$VMName-pip" `
        --nsg-rule ($OSFamily -eq "linux" ? "SSH" : "RDP") `
        --output json 2>&1 | ConvertFrom-Json

    $PublicIP = $vmOutput.publicIpAddress
    Write-Host "  Test VM deployed: $VMName  IP=$PublicIP"

    # Wait for SSH/WinRM to be responsive (up to 3 min)
    Write-Host "`n  Waiting for $OSFamily connectivity on $PublicIP ..."
    $timeout = 180; $elapsed = 0; $ready = $false
    while ($elapsed -lt $timeout -and -not $ready) {
        Start-Sleep 10; $elapsed += 10
        if ($OSFamily -eq "linux") {
            $test = Test-NetConnection -ComputerName $PublicIP -Port 22 -WarningAction SilentlyContinue
        } else {
            $test = Test-NetConnection -ComputerName $PublicIP -Port 3389 -WarningAction SilentlyContinue
        }
        $ready = $test.TcpTestSucceeded
        Write-Host "  [$elapsed s] Ready=$ready"
    }
    if (-not $ready) { throw "Test VM not reachable after $timeout seconds" }

    # ── INSTALL CERTIFICATION TOOL ─────────────────────────────────────────────
    Write-Host "`n[3/5] Installing Certification Test Tool v1.6"
    if (-not (Test-Path $ToolExe)) {
        New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null
        Write-Host "  Downloading from Microsoft..."
        Invoke-WebRequest -Uri $ToolUrl -OutFile "$ToolDir\certificationtool.msi" -UseBasicParsing
        Start-Process msiexec.exe -Wait -ArgumentList "/i `"$ToolDir\certificationtool.msi`" /quiet INSTALLDIR=`"$ToolDir`""
        Write-Host "  Tool installed at $ToolDir"
    } else {
        Write-Host "  Tool already present (cached)"
    }

    # ── RUN CERTIFICATION TOOL ─────────────────────────────────────────────────
    Write-Host "`n[4/5] Running Certification Tool against $PublicIP"
    $certArgs = @(
        "/vm", $PublicIP,
        "/user", $AdminUser,
        "/password", $AdminPass,
        "/os", $OSFamily,
        "/reportlocation", $ReportXml
    )
    $proc = Start-Process -FilePath $ToolExe -ArgumentList $certArgs -Wait -PassThru -NoNewWindow
    Write-Host "  Tool exited with code: $($proc.ExitCode)"

    # ── PARSE RESULTS ────────────────────────────────────────────────────────────
    Write-Host "`n[5/5] Parsing results from $ReportXml"
    if (-not (Test-Path $ReportXml)) {
        Write-Warning "  No report XML found — tool may have failed to connect"
        exit 1
    }

    [xml]$report = Get-Content $ReportXml
    $results = $report.SelectNodes("//TestResult")
    $failures = @()
    $warnings = @()
    $passes   = @()

    "# AzCertify Pre-flight Report`n" | Set-Content $SummaryMd
    "Generated: $(Get-Date -Format 'u')" | Add-Content $SummaryMd
    "`nImage: $ImageResourceId`n" | Add-Content $SummaryMd
    "| Test | Result | Details |" | Add-Content $SummaryMd
    "|------|--------|---------|" | Add-Content $SummaryMd

    foreach ($r in $results) {
        $name   = $r.TestName ?? $r.Name ?? "Unknown"
        $result = $r.Result ?? $r.Status ?? "UNKNOWN"
        $detail = ($r.Description ?? $r.Details ?? "") -replace "`n"," "
        "| $name | $result | $detail |" | Add-Content $SummaryMd

        switch ($result.ToUpper()) {
            "FAILED" { $failures += "$name`: $detail" }
            "ERROR"  { $failures += "ERROR in $name`: $detail" }
            "WARNING"{ $warnings += "$name`: $detail" }
            default  { $passes   += $name }
        }
    }

    Write-Host ""
    Write-Host "  ✅ Passed:   $($passes.Count)"
    Write-Host "  ⚠️  Warnings: $($warnings.Count)"
    Write-Host "  ❌ Failures: $($failures.Count)"

    if ($warnings.Count -gt 0) {
        Write-Host "`nWarnings:"
        $warnings | ForEach-Object { Write-Host "  ⚠️  $_" }
    }

    if ($failures.Count -gt 0) {
        Write-Host "`nFAILURES (must fix before publish):"
        $failures | ForEach-Object { Write-Host "  ❌ $_" }
        exit 1
    }

    Write-Host "`n✅ AzCertify Pre-flight PASSED — image is ready for Partner Center submission"

} finally {
    # ── CLEANUP TEST VM (always) ──────────────────────────────────────────────
    Write-Host "`n[Cleanup] Deleting test VM: $VMName"
    az vm delete --resource-group $ResourceGroup --name $VMName --yes --no-wait 2>&1 | Out-Null
    # Delete the PIP and NIC
    az network public-ip delete --resource-group $ResourceGroup --name "$VMName-pip" --no-wait 2>&1 | Out-Null
    Write-Host "  Test VM deletion initiated (async)"
}
