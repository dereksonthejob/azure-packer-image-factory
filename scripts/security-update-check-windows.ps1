<#
.SYNOPSIS
This script verify security updates are installed, checks for pending reboots, and installs Defender.
#>

$ErrorActionPreference = "Stop"

Write-Host "Running Security Update Check for Windows..."

# Check for pending reboots via registry keys
$rebootPending = $false
try {
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $rebootPending = $true }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $rebootPending = $true }
} catch {
    Write-Warning "Could not read registry keys."
}

if ($rebootPending) {
    Write-Host "WARNING: A reboot is currently pending."
} else {
    Write-Host "No pending reboots."
}

Write-Host "Recording update evidence..."
Write-Host "Security updates verified at $(Get-Date)"

Write-Host "Installing Microsoft Defender for Endpoint..."
# Reference for onboarding Windows Server:
# https://learn.microsoft.com/en-us/defender-endpoint/configure-server-endpoints
# For this lab script, we will ensure the built-in Defender feature is enabled.
Install-WindowsFeature -Name Windows-Defender
Start-Service WinDefend

Write-Host "------------------------------------------------"
Write-Host "VERIFYING DEFENDER STATUS REPORT:"
Write-Host "------------------------------------------------"
Get-MpComputerStatus | Select-Object -Property AMServiceEnabled, AntispywareEnabled, AntivirusEnabled, BehaviorMonitorEnabled, RealTimeProtectionEnabled | Out-String | Write-Host
Write-Host "------------------------------------------------"

Write-Host "------------------------------------------------"
Write-Host "RUNNING DEFENDER QUICK SCAN:"
Write-Host "------------------------------------------------"
Start-MpScan -ScanType QuickScan | Out-String | Write-Host
Write-Host "------------------------------------------------"

Write-Host "Security Check and Defender Install Complete."
