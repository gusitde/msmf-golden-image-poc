###############################################################################
# MS Migration Factory — Golden Image Prep
# Stage 2b : COMPUTE — input variables
# File     : terraform/variables.compute.tf
#
# All variables here are namespaced `compute_*` / `jfrog_*` (plus the
# `image_source` toggle which this stage owns) so they never collide with
# blocks declared by the network / policy / octopus authors.
#
# ---------------------------------------------------------------------------
# SHARED INPUTS CONSUMED BY compute.tf (declared ONCE in the shared variables.tf
# / providers.tf — NOT re-declared here):
#
#   var.location            (string)  Azure region                  [variables.tf]
#   var.environment         (string)  dev|test|prod                 [variables.tf]
#   var.owner               (string)  owner tag                     [variables.tf]
#   var.project_name        (string)  project id / tag              [variables.tf]
#   var.resource_group_name (string)  workload RG name (nullable)   [variables.tf]
#   var.enable_telemetry    (bool)    AVM telemetry toggle          [variables.tf]
#   var.octopus_server_url  (string)  Octopus base URL              [variables.tf]
#   var.octopus_api_key     (string, sensitive) Octopus API key     [variables.tf]
#   local.common_tags       (map)     canonical tag map             [providers.tf]
#   module.resource_group.name        workload RG                   [network.tf]
#   module.vnet.subnets["app"].resource_id  app subnet id           [network.tf]
###############################################################################

#=============================================================================#
# Image source toggle (owned by the compute stage — it consumes the image)
#=============================================================================#
variable "image_source" {
  type        = string
  description = "Where the golden OS image comes from: 'gallery' (Azure Compute Gallery image version) or 'jfrog' (VHD pulled from JFrog Artifactory into a managed image)."
  default     = "gallery"

  validation {
    condition     = contains(["gallery", "jfrog"], var.image_source)
    error_message = "image_source must be either \"gallery\" or \"jfrog\"."
  }
}

#=============================================================================#
# Golden image — Azure Compute Gallery (Shared Image Gallery) path
#=============================================================================#
# NOTE: the three gallery/image-definition defaults below are the CROSS-STAGE
# CONTRACT with Stage 1 -- they are IDENTICAL to the Packer defaults in
# packer/variables.pkr.hcl (gallery_resource_group / gallery_name /
# image_definition_name), so data.azurerm_shared_image_version.golden resolves
# exactly what `packer build` publishes. Change them together or not at all.
variable "compute_compute_gallery_name" {
  type        = string
  description = "Name of the Azure Compute Gallery (Shared Image Gallery) that holds the golden image. Must match Packer's gallery_name. Required when image_source = \"gallery\"."
  default     = "gal_msmf"
}

variable "compute_image_definition_name" {
  type        = string
  description = "Compute Gallery image DEFINITION name for the golden image (e.g. Windows Server + IIS + Tentacle)."
  default     = "win2022-iis-octopus"
}

variable "compute_image_version" {
  type        = string
  description = "Image VERSION to deploy. Accepts an exact semver (e.g. \"1.0.20260718\") or the special values \"latest\"/\"recent\"."
  default     = "latest"
}

variable "compute_gallery_resource_group_name" {
  type        = string
  description = "Resource group that contains the Compute Gallery. Must match Packer's gallery_resource_group (the images RG Stage 1 publishes into). Set to null to fall back to the workload RG instead."
  default     = "rg-msmf-gallery"
}

variable "compute_image_hyper_v_generation" {
  type        = string
  description = "Hyper-V generation of the golden image (\"V1\" or \"V2\"). Used for the JFrog managed-image path."
  default     = "V2"

  validation {
    condition     = contains(["V1", "V2"], var.compute_image_hyper_v_generation)
    error_message = "compute_image_hyper_v_generation must be \"V1\" or \"V2\"."
  }
}

#=============================================================================#
# Golden image — JFrog Artifactory (VHD) path
#=============================================================================#
variable "jfrog_base_url" {
  type        = string
  description = "Base URL of the JFrog Artifactory instance (e.g. https://acme.jfrog.io/artifactory)."
  default     = ""
}

variable "jfrog_repo_path" {
  type        = string
  description = "Repository path to the golden VHD within Artifactory (e.g. golden-images-vhd/win2022-iis-octopus/osdisk.vhd)."
  default     = ""
}

variable "jfrog_username" {
  type        = string
  description = "Artifactory username (used only if jfrog_access_token is empty). Passed to the import script via env var, never stored on the command line."
  sensitive   = true
  default     = ""
}

variable "jfrog_password" {
  type        = string
  description = "Artifactory password / API key for basic auth (used only if jfrog_access_token is empty)."
  sensitive   = true
  default     = ""
}

variable "jfrog_access_token" {
  type        = string
  description = "Artifactory identity/access token (preferred; sent as a Bearer header). Takes precedence over username/password."
  sensitive   = true
  default     = ""
}

variable "jfrog_staging_storage_account_name" {
  type        = string
  description = "Storage account used to stage the imported VHD as a page blob. Assumed to already exist (network/storage stage or pre-provisioned)."
  default     = ""
}

variable "jfrog_staging_resource_group_name" {
  type        = string
  description = "Resource group of the JFrog staging storage account. Defaults to the shared resource_group_name when null."
  default     = null
}

variable "jfrog_staging_container" {
  type        = string
  description = "Blob container in the staging storage account for the imported VHD."
  default     = "vhds"
}

variable "jfrog_vhd_blob_name" {
  type        = string
  description = "Destination page-blob name for the imported golden VHD."
  default     = "golden-image-osdisk.vhd"
}

variable "compute_jfrog_os_disk_size_gb" {
  type        = number
  description = "OS disk size (GB) for the managed image built from the JFrog VHD. Must be >= the VHD's virtual size."
  default     = 127
}

#=============================================================================#
# Placement (resource group + subnet)
#=============================================================================#
variable "compute_resource_group_name" {
  type        = string
  description = "Resource group to place the VMs in. Defaults to the workload RG created by the network stage (module.resource_group.name) when null."
  default     = null
}

variable "compute_subnet_id" {
  type        = string
  description = "Resource id of the application subnet the VMs attach to. Defaults to the network stage's app subnet (module.vnet.subnets[\"app\"].resource_id) when null. Set explicitly to attach to an existing/peered network instead."
  default     = null
}

variable "compute_enable_public_ip" {
  type        = bool
  description = "Create a public IP per VM. Default false — keep VMs private behind the subnet NSG; enable only for Octopus Listening-mode reachability or explicit ingress needs."
  default     = false
}

#=============================================================================#
# Virtual machines
#=============================================================================#
variable "compute_vm_name_prefix" {
  type        = string
  description = "Prefix for VM names. Instances are suffixed -01, -02, ... (e.g. vm-msmf-01)."
  default     = "vm-msmf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,12}$", var.compute_vm_name_prefix))
    error_message = "compute_vm_name_prefix must be 2-13 chars, lowercase alphanumeric or hyphen, starting with a letter (keeps Windows computer names <= 15 chars)."
  }
}

variable "compute_vm_count" {
  type        = number
  description = "Number of Windows VMs to create from the golden image."
  default     = 2

  validation {
    condition     = var.compute_vm_count >= 1 && floor(var.compute_vm_count) == var.compute_vm_count
    error_message = "compute_vm_count must be a whole number >= 1."
  }
}

variable "compute_vm_size" {
  type        = string
  description = "Azure VM size/SKU for the deployment targets."
  default     = "Standard_D2s_v5"
}

variable "compute_availability_zones" {
  type        = list(string)
  description = "Availability zones to round-robin VMs across (e.g. [\"1\",\"2\",\"3\"]). Use a single-element list for zonal-pinned/one-zone regions."
  default     = ["1", "2", "3"]

  validation {
    condition     = length(var.compute_availability_zones) >= 1
    error_message = "Provide at least one availability zone."
  }
}

variable "compute_admin_username" {
  type        = string
  description = "Local administrator username for the Windows VMs."
  default     = "msmfadmin"

  validation {
    condition     = !contains(["administrator", "admin", "root", "guest"], lower(var.compute_admin_username))
    error_message = "compute_admin_username must not be a reserved Windows name (administrator/admin/root/guest)."
  }
}

variable "compute_admin_password" {
  type        = string
  description = "Local administrator password. Supply via TF_VAR_compute_admin_password or a Key Vault-sourced value — NEVER commit it. Leave null to have the module generate one (persist it in Key Vault for production)."
  sensitive   = true
  default     = null
}

variable "compute_os_disk_storage_account_type" {
  type        = string
  description = "OS managed-disk storage account type."
  default     = "Premium_LRS"

  validation {
    condition     = contains(["Standard_LRS", "StandardSSD_LRS", "Premium_LRS", "StandardSSD_ZRS", "Premium_ZRS"], var.compute_os_disk_storage_account_type)
    error_message = "compute_os_disk_storage_account_type must be a valid Azure managed disk SKU."
  }
}

variable "compute_boot_diagnostics_storage_uri" {
  type        = string
  description = "Boot diagnostics storage blob endpoint. Leave null to use an Azure-managed diagnostics storage account (recommended)."
  default     = null
}

variable "compute_additional_tags" {
  type        = map(string)
  description = "Extra tags merged onto every compute resource (on top of project/env/owner)."
  default     = {}
}

#=============================================================================#
# Octopus Tentacle registration (compute-side boot bootstrap)
#=============================================================================#
variable "compute_octopus_space_name" {
  type        = string
  description = "Octopus Space to register the Tentacle into."
  default     = "Default"
}

variable "compute_octopus_environment" {
  type        = string
  description = "Octopus Environment name to register the Tentacle into. Null (default) = derive from the shared `environment` via the Stage 3 environment-name variables (dev -> octopus_dev_environment_name \"Development\", test -> \"Test\", prod -> \"Production\"), so registration always matches an environment octopus.tf creates. Set explicitly only for a non-standard mapping."
  default     = null
}

variable "compute_octopus_target_roles" {
  type        = list(string)
  description = "Octopus target Role(s) assigned to the registered machines (used by the deployment process to select targets)."
  default     = ["msmf-web", "iis-web-server"]

  validation {
    condition     = length(var.compute_octopus_target_roles) >= 1
    error_message = "Provide at least one Octopus target role."
  }
}

variable "compute_octopus_comms_style" {
  type        = string
  description = "Tentacle communication style: 'Polling' (TentacleActive — outbound to server:10943, cloud-friendly, default) or 'Listening' (TentaclePassive — server connects inbound to :10933)."
  default     = "Polling"

  validation {
    condition     = contains(["Polling", "Listening"], var.compute_octopus_comms_style)
    error_message = "compute_octopus_comms_style must be \"Polling\" or \"Listening\"."
  }
}

variable "compute_octopus_listen_port" {
  type        = number
  description = "Inbound TCP port the Tentacle listens on in Listening mode."
  default     = 10933
}

variable "compute_octopus_polling_port" {
  type        = number
  description = "Octopus Server comms port the Tentacle polls in Polling mode."
  default     = 10943
}

variable "compute_octopus_server_thumbprint" {
  type        = string
  description = "Octopus Server X509 certificate thumbprint. Required for Listening mode (the Tentacle trusts only this thumbprint). Optional for Polling."
  default     = null
}

variable "compute_octopus_machine_policy" {
  type        = string
  description = "Octopus Machine Policy to assign to the registered targets."
  default     = "Default Machine Policy"
}

variable "compute_tentacle_instance_name" {
  type        = string
  description = "Octopus Tentacle instance name on the VM."
  default     = "Tentacle"
}

variable "compute_tentacle_applications_dir" {
  type        = string
  description = "Directory on the VM where Octopus deploys application packages."
  default     = "C:\\Octopus\\Applications"
}
