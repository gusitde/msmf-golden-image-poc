# =============================================================================
# MS Migration Factory - Golden Image Prep  |  Stage 1 (Packer) variables
# -----------------------------------------------------------------------------
# All inputs for windows-golden-image.pkr.hcl. Secrets (client_secret,
# octopus_api_key) are marked sensitive so Packer redacts them from logs.
# Supply values via windows-golden-image.pkrvars.hcl (git-ignored) or -var/env:
#   PKR_VAR_client_secret=... / PKR_VAR_octopus_api_key=...
# In CI, source these from Azure Key Vault / Octopus sensitive variables.
# =============================================================================

# ------------------------------------------------------------------ Azure auth
variable "subscription_id" {
  type        = string
  description = "Azure subscription ID that hosts the build VM and the Compute Gallery."
}

variable "tenant_id" {
  type        = string
  description = "Azure AD tenant ID. Required for service-principal auth; optional with Azure CLI auth."
  default     = ""
}

variable "client_id" {
  type        = string
  description = "Service principal (app) client ID. Leave empty when use_azure_cli_auth = true."
  default     = ""
}

variable "client_secret" {
  type        = string
  description = "Service principal client secret. Leave empty when use_azure_cli_auth = true."
  default     = ""
  sensitive   = true
}

variable "use_azure_cli_auth" {
  type        = bool
  description = "Set to true to authenticate with the logged-in `az` CLI context instead of a service principal."
  default     = false
}

# ------------------------------------------------------------- Build placement
variable "location" {
  type        = string
  description = "Azure region for the temporary build VM. PoC default: East US."
  default     = "eastus"
}

variable "vm_size" {
  type        = string
  description = "VM size used for the ephemeral build VM (not the produced image)."
  default     = "Standard_D2s_v5"
}

variable "os_disk_size_gb" {
  type        = number
  description = "OS disk size (GB) for the build VM / captured image."
  default     = 128
}

variable "build_resource_group_name" {
  type        = string
  description = "Optional existing resource group to build in. Empty = Packer creates a temporary RG it also deletes."
  default     = ""
}

# ---------------------------------------------------------- Base (source) image
variable "image_publisher" {
  type        = string
  description = "Marketplace publisher of the base OS image."
  default     = "MicrosoftWindowsServer"
}

variable "image_offer" {
  type        = string
  description = "Marketplace offer of the base OS image."
  default     = "WindowsServer"
}

variable "image_sku" {
  type        = string
  description = "Marketplace SKU. Default is Windows Server 2022 Datacenter Gen2. (Use 2022-datacenter-azure-edition for Azure Edition; requires a matching Gen2 image definition.)"
  default     = "2022-datacenter-g2"
}

variable "base_image_version" {
  type        = string
  description = "Version of the base marketplace image to build from."
  default     = "latest"
}

# ----------------------------------------------- Output: Azure Compute Gallery
# NOTE: these defaults are the CROSS-STAGE CONTRACT with Terraform Stage 2b --
# they must stay identical to terraform/variables.compute.tf's
# compute_gallery_resource_group_name / compute_compute_gallery_name /
# compute_image_definition_name defaults so the compute stage's
# data.azurerm_shared_image_version.golden resolves exactly what Packer
# publishes. Change them together or not at all.
variable "gallery_resource_group" {
  type        = string
  description = "Resource group that contains the target Azure Compute Gallery (must already exist). Must match Terraform's compute_gallery_resource_group_name."
  default     = "rg-msmf-gallery"
}

variable "gallery_name" {
  type        = string
  description = "Name of the target Azure Compute Gallery (Shared Image Gallery). Must match Terraform's compute_compute_gallery_name."
  default     = "gal_msmf"
}

variable "image_definition_name" {
  type        = string
  description = "Existing image *definition* inside the gallery to publish the version under (OS state must be Generalized, Gen2/V2)."
  default     = "win2022-iis-octopus"
}

variable "image_version" {
  type        = string
  description = "Semantic image version to publish, e.g. 1.0.0. Bump per build."
  default     = "1.0.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.image_version))
    error_message = "image_version must be MAJOR.MINOR.PATCH, e.g. 1.0.0."
  }
}

variable "replication_regions" {
  type        = list(string)
  description = "Regions the image version is replicated to."
  default     = ["eastus"]
}

variable "image_storage_account_type" {
  type        = string
  description = "Replica storage account type for the gallery image version."
  default     = "Standard_LRS"

  validation {
    condition     = contains(["Standard_LRS", "Standard_ZRS", "Premium_LRS"], var.image_storage_account_type)
    error_message = "image_storage_account_type must be one of Standard_LRS, Standard_ZRS, Premium_LRS."
  }
}

# --------------------------------------------------------- Octopus Deploy inputs
variable "octopus_register_during_build" {
  type        = bool
  description = "If true, the Tentacle is fully registered with Octopus during the build. Keep FALSE for real golden images (defer registration to first boot so every cloned VM gets a unique identity). True is only for single-VM demos."
  default     = false
}

variable "octopus_server_url" {
  type        = string
  description = "Octopus Server base URL, e.g. https://your-octopus.octopus.app. Only used when registering."
  default     = ""
}

variable "octopus_api_key" {
  type        = string
  description = "Octopus API key (API-XXXXXXXX) used for registration. Only used when registering."
  default     = ""
  sensitive   = true
}

variable "octopus_space" {
  type        = string
  description = "Octopus space name the target registers into."
  default     = "Default"
}

variable "octopus_environment" {
  type        = string
  description = "Octopus environment to register the target into during build (demo only)."
  default     = "Dev"
}

variable "octopus_roles" {
  type        = list(string)
  description = "Octopus target roles applied at registration (used by the deployment process to select targets)."
  default     = ["web-server", "iis"]
}

variable "octopus_comms_style" {
  type        = string
  description = "Tentacle communication style: 'Listen' (Octopus -> Tentacle, port 10933) or 'Poll' (Tentacle -> Octopus, port 10943)."
  default     = "Poll"

  validation {
    condition     = contains(["Listen", "Poll"], var.octopus_comms_style)
    error_message = "octopus_comms_style must be 'Listen' or 'Poll'."
  }
}

variable "octopus_listen_port" {
  type        = number
  description = "TCP port the Listening Tentacle listens on (opened in the Windows firewall)."
  default     = 10933
}

variable "octopus_server_comms_port" {
  type        = number
  description = "TCP port a Polling Tentacle uses to reach the Octopus Server."
  default     = 10943
}

variable "octopus_server_thumbprint" {
  type        = string
  description = "Octopus Server X509 thumbprint used to establish trust for a Listening Tentacle. Optional; register-with can establish trust via the API key when omitted."
  default     = ""
}

variable "octopus_instance_name" {
  type        = string
  description = "Local Tentacle instance name."
  default     = "Tentacle"
}

variable "tentacle_download_url" {
  type        = string
  description = "URL of the Octopus Tentacle MSI (x64). Default resolves to the current stable release. For reproducible/verifiable builds, pin a specific version URL and set tentacle_msi_sha256."
  default     = "https://octopus.com/downloads/latest/WindowsX64/OctopusTentacle"
}

variable "tentacle_msi_sha256" {
  type        = string
  description = "Expected SHA256 checksum of the Tentacle MSI. When set, install-octopus-tentacle.ps1 fails the build on mismatch (supply-chain guard for a binary installed as SYSTEM and cloned fleet-wide). Empty = skip verification with a warning; ALWAYS set this together with a pinned tentacle_download_url for production images."
  default     = ""
}

# ------------------------------------------------------------------------ Tags
variable "env" {
  type        = string
  description = "Environment label applied as the `env` tag (dev|test|prod)."
  default     = "dev"
}

variable "owner" {
  type        = string
  description = "Owner tag value (team or individual responsible for the image)."
  default     = "platform-engineering"
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional tags merged onto every Azure resource the build creates and onto the image version."
  default     = {}
}
