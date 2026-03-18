<#
.SYNOPSIS
  One-time setup: creates the two persistent AzCertify test VMs.
  Run ONCE per subscription. VMs are reused across all subsequent builds.

.DESCRIPTION
  Creates:
    vm-certtest-windows-eastus  (Standard_D4s_v4, WS2022 base)
    vm-certtest-linux-eastus    (Standard_D4ps_v5, Ubuntu 24.04 base)

  Stores the admin password in Key Vault as 'certtest-vm-password'.
  The GitHub secret CERTTEST_VM_PASSWORD must be set from Key Vault.

.PARAMETER KeyVaultName
  Name of the Key Vault to store the VM admin password.
#>
param(
    [Parameter(Mandatory=$true)] [string] $KeyVaultName,
    [string] $RG       = "RG-AZCERTIFY-PREFLIGHT",
    [string] $Location = "eastus",
    [string] $VNet     = "vnet-gh-runners-eastus",
    [string] $VNetRG   = "rg-github-runner-platform-eastus",
    [string] $Subnet   = "snet-gh-runners"
)

$ErrorActionPreference = "Stop"
$AdminUser = "azurecertify"

# Generate a strong password and store in Key Vault
Add-Type -AssemblyName System.Web
$Password = [System.Web.Security.Membership]::GeneratePassword(20, 4)
az keyvault secret set --vault-name $KeyVaultName --name "certtest-vm-password" --value $Password --output none
Write-Host "✅ Password stored in Key Vault: $KeyVaultName/certtest-vm-password"
Write-Host "   → Set this as GitHub secret CERTTEST_VM_PASSWORD"

# Create resource group
az group create --name $RG --location $Location --output none
Write-Host "✅ Resource group: $RG"

# ── Windows VM ─────────────────────────────────────────────────────────────────
Write-Host "`nCreating vm-certtest-windows-eastus..."
az vm create `
    --resource-group $RG `
    --name "vm-certtest-windows-eastus" `
    --image "MicrosoftWindowsServer:WindowsServer:2022-datacenter-g2:latest" `
    --size "Standard_D4s_v4" `
    --admin-username $AdminUser `
    --admin-password $Password `
    --vnet-name $VNet `
    --vnet-resource-group $VNetRG `
    --subnet $Subnet `
    --public-ip-address "pip-certtest-windows-eastus" `
    --nsg-rule RDP `
    --output none
Write-Host "✅ vm-certtest-windows-eastus created"

# Install Certification Tool v1.6 on Windows VM via Custom Script Extension
$ToolUrl = "https://download.microsoft.com/download/B/0/7/B0745BE4-4BE2-4478-85FE-28C0B86A4C1E/Certification%20Test%20Tool%201.6%20for%20Azure%20Certified.msi"
$installScript = "Invoke-WebRequest -Uri '$ToolUrl' -OutFile C:\certificationtool.msi; Start-Process msiexec -Wait -ArgumentList '/i C:\certificationtool.msi /quiet INSTALLDIR=C:\CertificationTool'"
az vm run-command invoke `
    --resource-group $RG `
    --name "vm-certtest-windows-eastus" `
    --command-id RunPowerShellScript `
    --scripts $installScript `
    --output none
Write-Host "✅ Certification Tool v1.6 installed on Windows VM"

# ── Linux VM ───────────────────────────────────────────────────────────────────
Write-Host "`nCreating vm-certtest-linux-eastus..."
az vm create `
    --resource-group $RG `
    --name "vm-certtest-linux-eastus" `
    --image "Canonical:ubuntu-24_04-lts:server:latest" `
    --size "Standard_D4ps_v5" `
    --admin-username $AdminUser `
    --admin-password $Password `
    --vnet-name $VNet `
    --vnet-resource-group $VNetRG `
    --subnet $Subnet `
    --public-ip-address "pip-certtest-linux-eastus" `
    --nsg-rule SSH `
    --output none
Write-Host "✅ vm-certtest-linux-eastus created"

Write-Host "`n================================================================"
Write-Host "  Bootstrap complete. Both test VMs are ready."
Write-Host "  NEXT STEP: Set GitHub secret CERTTEST_VM_PASSWORD from Key Vault"
Write-Host "  az keyvault secret show --vault-name $KeyVaultName --name certtest-vm-password --query value -o tsv"
Write-Host "================================================================"
