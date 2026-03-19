packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = ">= 2.0.0"
    }
    windows-update = {
      version = ">= 0.14.3"
      source  = "github.com/rgl/windows-update"
    }
  }
}

variable "profile_id" { type = string }
variable "location" { type = string }
variable "build_resource_group_name" { type = string }
variable "temp_resource_group_name" {
  type    = string
  default = ""
}

variable "vm_size" { type = string }
variable "managed_image_name" { type = string }
variable "source_image_publisher" { type = string }
variable "source_image_offer" { type = string }
variable "source_image_sku" { type = string }
variable "source_image_version" { type = string }
variable "gallery_resource_group" { type = string }
variable "gallery_name" { type = string }
variable "image_definition" { type = string }
variable "image_version" { type = string }
variable "replication_regions" { type = list(string) }
variable "plan_info_publisher" { type = string }
variable "plan_info_product" { type = string }
variable "plan_info_name" { type = string }

variable "azure_tags" {
  type    = map(string)
  default = {}
}

source "azure-arm" "image" {
  use_azure_cli_auth = true
  build_resource_group_name = var.build_resource_group_name
  virtual_network_resource_group_name = "rg-github-runner-platform-eastus"
  virtual_network_name                = "vnet-gh-runners-eastus"
  virtual_network_subnet_name         = "snet-gh-runners"

  os_type                           = "Windows"
  image_publisher                   = var.source_image_publisher
  image_offer                       = var.source_image_offer
  image_sku                         = var.source_image_sku
  image_version                     = var.source_image_version
  vm_size                           = var.vm_size
  managed_image_name                = var.managed_image_name
  managed_image_resource_group_name = var.build_resource_group_name

  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "10m"
  winrm_username = "packer"

  # Cap ARM polling so a hung deployment fails fast instead of blocking for hours
  polling_duration_timeout = "45m"

  azure_tags = var.azure_tags

  shared_image_gallery_destination {
    resource_group      = var.gallery_resource_group
    gallery_name        = var.gallery_name
    image_name          = var.image_definition
    image_version       = var.image_version
    replication_regions = var.replication_regions
  }

  plan_info {
    plan_name      = var.plan_info_name
    plan_product   = var.plan_info_product
    plan_publisher = var.plan_info_publisher
  }
}

build {
  sources = ["source.azure-arm.image"]

  provisioner "powershell" {
    scripts = [
      "${path.root}/../../scripts/security-update-check-windows.ps1"
    ]
  }

  # First pass: apply all non-Preview Windows Updates
  provisioner "windows-update" {
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true"
    ]
    update_limit = 1000
  }

  # Second pass: catch any updates that became available after the first reboot cycle
  provisioner "windows-update" {
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true"
    ]
    update_limit = 1000
  }


  # -----------------------------------------------------------------------
  # MANDATORY: Policy 200.4.2 — Remove Microsoft Defender ATP before capture
  # Windows marketplace source images ship with Defender pre-installed.
  # Failure to offboard results in certification rejection on ALL plans.
  # -----------------------------------------------------------------------
  provisioner "file" {
    source      = "${path.root}/../../scripts/Invoke-MarketplaceImageHardening.ps1"
    destination = "C:\\Windows\\Temp\\Invoke-MarketplaceImageHardening.ps1"
    direction   = "upload"
  }

  provisioner "powershell" {
    inline = [
      "# Policy 200.4.2 (Defender ATP) + Policy 200.5.8 (.NET 6 EOL)",
      "& C:\\Windows\\Temp\\Invoke-MarketplaceImageHardening.ps1 -ErrorAction Stop"
    ]
  }


  provisioner "powershell" {
    inline = [
      "$deadline = (Get-Date).AddMinutes(10)",
      "while ((Get-Service RdAgent).Status -ne 'Running') { if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for RdAgent' }; Start-Sleep -s 5 }",
      "Write-Output 'Running sysprep and baseline...'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit"
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/packer-manifest.json"
    strip_path = true
  }
}
