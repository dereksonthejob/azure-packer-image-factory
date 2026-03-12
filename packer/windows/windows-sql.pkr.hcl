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
variable "vm_admin_password" {
  type      = string
  sensitive = true
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
  winrm_timeout  = "2h"
  winrm_username = "packer"

  azure_tags = var.azure_tags

  shared_image_gallery_destination {
    resource_group      = var.gallery_resource_group
    gallery_name        = var.gallery_name
    image_name          = var.image_definition
    image_version       = var.image_version
    replication_regions = var.replication_regions
  }
}

build {
  sources = ["source.azure-arm.image"]

  provisioner "powershell" {
    scripts = [
      "${path.root}/../../scripts/security-update-check-windows.ps1"
    ]
  }

  provisioner "windows-update" {
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true"
    ]
    update_limit = 25
  }


  provisioner "powershell" {
    inline = [
      "while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep -s 5 }",
      "Write-Output 'Running sysprep and baseline...'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit"
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/packer-manifest.json"
    strip_path = true
  }
}
