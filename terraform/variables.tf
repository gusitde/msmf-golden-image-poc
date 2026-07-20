###############################################################################
# variables.tf  --  SHARED variable declarations for the MSMF Golden-Image PoC.
#
# Ownership / namespacing convention (multi-author root module):
#   * SHARED / plumbing block  ....... owned by the Network stage (this file)
#   * NETWORK block            ....... owned by the Network stage (this file)
#   * COMPUTE block            ....... appended by the Compute stage author
#   * OCTOPUS / CI-CD block     ...... appended by the Octopus stage author
#   * POLICY block             ....... appended by the Policy stage author
#
# Each stage prefixes its inputs (net_*, vm_*, octo_*, policy_*) OR uses an
# obviously-scoped name to avoid collisions. A Terraform variable may be
# declared only once per module, so do NOT re-declare anything below.
###############################################################################

# =========================================================================== #
#  SHARED / PLUMBING  (used by providers.tf and by every stage)
# =========================================================================== #

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID. Null => fall back to ARM_SUBSCRIPTION_ID / Azure CLI context (required by azurerm 4.x)."
  default     = null
}

variable "tenant_id" {
  type        = string
  description = "Azure AD tenant ID. Null => fall back to ARM_TENANT_ID / Azure CLI context."
  default     = null
}

variable "location" {
  type        = string
  description = "Azure region for all resources in this stack. PoC default: East US."
  default     = "eastus"

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty (e.g. \"eastus\")."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment. Surfaces as the `env` tag and in resource names."
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, prod."
  }
}

variable "owner" {
  type        = string
  description = "Owner tag value (team or individual accountable for the workload)."
  default     = "platform-engineering"
}

variable "project_name" {
  type        = string
  description = "Project identifier. Drives the `project` tag and the default resource-name prefix."
  default     = "msmf-golden-image"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags merged onto local.common_tags (e.g. cost-center, ticket)."
  default     = {}
}

variable "enable_telemetry" {
  type        = bool
  description = "Azure Verified Modules telemetry. Emits a tiny, data-free ARM deployment per module so Microsoft can measure AVM usage. Off by default for customer subscriptions; safe to enable."
  default     = false
}

# --- Octopus Deploy connection (consumed by providers.tf; resources by the
#     Octopus stage). Kept here because providers.tf is shared. --------------

variable "enable_octopus_stage" {
  type        = bool
  description = <<-EOT
    Master switch for Stage 3 (Octopus). When false (the default) EVERY
    octopusdeploy resource AND data source is gated off (count = 0), so
    `terraform plan`/`apply` of the network + compute stages succeeds with NO
    reachable Octopus server and the placeholder octopus_server_url /
    empty octopus_api_key defaults. Set to true (with real connection values)
    to create the Octopus environments, lifecycle, project and deployment
    process.
  EOT
  default     = false
}

variable "octopus_server_url" {
  type        = string
  description = "Octopus Server base URL, e.g. https://your-octopus.octopus.app."
  default     = "https://your-octopus-instance.octopus.app"
}

variable "octopus_api_key" {
  type        = string
  description = "Octopus API key (API-XXXXXXXX). Supply via TF_VAR_octopus_api_key from Key Vault / a pipeline secret -- never commit. NOTE: `sensitive` only redacts CLI output; the value still reaches Terraform STATE via the compute extension's protected_settings (it cannot be `ephemeral` because it must persist there) -- see the README 'State hygiene' section: encrypted remote backend + rotate after provisioning."
  default     = ""
  sensitive   = true
}

variable "octopus_space_id" {
  type        = string
  description = "Octopus Space ID (e.g. Spaces-1). Newer provider versions also accept the Space name."
  default     = "Spaces-1"
}

# =========================================================================== #
#  NETWORK  (Stage 2a -- this stage)
# =========================================================================== #

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to create for the workload. Null => computed as rg-<project>-<env>."
  default     = null
}

variable "vnet_address_space" {
  type        = list(string)
  description = "Address space(s) for the virtual network."
  default     = ["10.10.0.0/16"]

  validation {
    condition     = length(var.vnet_address_space) > 0 && alltrue([for c in var.vnet_address_space : can(cidrhost(c, 0))])
    error_message = "vnet_address_space must contain one or more valid CIDR blocks."
  }
}

variable "app_subnet_address_prefixes" {
  type        = list(string)
  description = "CIDR prefixes for the application subnet (IIS web servers / Octopus deployment targets)."
  default     = ["10.10.1.0/24"]

  validation {
    condition     = length(var.app_subnet_address_prefixes) > 0 && alltrue([for c in var.app_subnet_address_prefixes : can(cidrhost(c, 0))])
    error_message = "app_subnet_address_prefixes must contain one or more valid CIDR blocks."
  }
}

variable "mgmt_subnet_address_prefixes" {
  type        = list(string)
  description = "CIDR prefixes for the management subnet (jump host / bastion-style admin access)."
  default     = ["10.10.2.0/24"]

  validation {
    condition     = length(var.mgmt_subnet_address_prefixes) > 0 && alltrue([for c in var.mgmt_subnet_address_prefixes : can(cidrhost(c, 0))])
    error_message = "mgmt_subnet_address_prefixes must contain one or more valid CIDR blocks."
  }
}

variable "mgmt_rdp_source_cidrs" {
  type        = list(string)
  description = "Source CIDRs allowed to RDP (3389) into the management subnet. Use your corporate/VPN range."
  default     = ["10.0.0.0/8"]

  validation {
    # Security baseline: never expose RDP to the whole Internet.
    condition = alltrue([
      for c in var.mgmt_rdp_source_cidrs :
      !contains(["0.0.0.0/0", "*", "Internet", "Any"], c)
    ])
    error_message = "mgmt_rdp_source_cidrs must not open RDP to the Internet (0.0.0.0/0, *, Internet, Any). Provide a specific corporate/VPN CIDR."
  }
}

variable "app_http_source_prefix" {
  type        = string
  description = "Source for inbound HTTPS (and, when app_enable_http = true, plain HTTP) to the app subnet. A single CIDR or an Azure service tag (e.g. Internet, VirtualNetwork, or an Application Gateway subnet CIDR)."
  default     = "Internet"
}

variable "app_enable_http" {
  type        = bool
  description = <<-EOT
    Opt-in switch for the plain-HTTP (port 80) inbound NSG rule on the app
    subnet. Default false = HTTPS-only: unencrypted HTTP is NOT reachable from
    app_http_source_prefix until an operator deliberately enables it (e.g. for
    a quick demo without a certificate, or behind an App Gateway that owns TLS
    termination and probes port 80).
  EOT
  default     = false
}

variable "octopus_server_source_cidrs" {
  type        = list(string)
  description = <<-EOT
    Source CIDRs allowed to reach the Octopus Tentacle listening port (10933)
    on deployment targets. This rule is only required for LISTENING Tentacles
    (Octopus Server -> target). For POLLING Tentacles (the Packer default,
    target -> Octopus:10943) it is unused and can be left as-is -- outbound is
    permitted by the default NSG egress rule.

    Set this to the Octopus Server's public IP/CIDR (self-hosted) or the
    published Octopus Cloud static IPs. Defaulted to the VNet range only so the
    rule is syntactically valid out of the box -- OVERRIDE for real use.
  EOT
  default     = ["10.10.0.0/16"]
}

# =========================================================================== #
#  POLICY  (Stage 2c -- security-compliance baseline, policy.tf)
# =========================================================================== #

variable "compliance_initiative" {
  type        = string
  description = <<-EOT
    The RECOGNIZED Azure built-in Policy Initiative the the security-compliance baseline
    maps to, assigned at the workload RG scope alongside the targeted deny
    controls. One of:
      "mcsb"     = Microsoft Cloud Security Benchmark (default; Azure's own baseline)
      "cis"      = CIS Microsoft Azure Foundations Benchmark v2.0.0
      "nist"     = NIST SP 800-53 Rev. 5
      "iso27001" = ISO 27001:2013
      "none"     = skip the recognized initiative (targeted deny controls only)
    Replace with the exact an organization-specific control set for an organization-specific control set.
  EOT
  default     = "mcsb"

  validation {
    condition     = contains(["mcsb", "cis", "nist", "iso27001", "none"], var.compliance_initiative)
    error_message = "compliance_initiative must be one of: mcsb, cis, nist, iso27001, none."
  }
}

variable "policy_enforcement_mode" {
  type        = string
  description = <<-EOT
    Enforcement mode for every policy assignment created by policy.tf.
      "Default"      = ENFORCED (deny-effect policies block non-compliant
                       creates). This is the default -- the baseline is real,
                       not advisory.
      "DoNotEnforce" = audit-only. Relax to this for a first exploratory run
                       if you need to see what WOULD be denied without
                       blocking the apply.
  EOT
  default     = "Default"

  validation {
    condition     = contains(["Default", "DoNotEnforce"], var.policy_enforcement_mode)
    error_message = "policy_enforcement_mode must be \"Default\" (enforce) or \"DoNotEnforce\" (audit-only)."
  }
}

variable "policy_allowed_locations" {
  type        = list(string)
  description = "Azure regions resources may be created in (built-in 'Allowed locations' policy). Keep in sync with var.location and the Packer replication_regions."
  default     = ["eastus", "eastus2"]

  validation {
    condition     = length(var.policy_allowed_locations) > 0
    error_message = "policy_allowed_locations must contain at least one region."
  }
}

variable "policy_required_tag_keys" {
  type        = list(string)
  description = "Tag keys every resource in the workload RG must carry (one 'Require a tag on resources' assignment per key). The PoC baseline is project/env/owner -- exactly what local.common_tags applies."
  default     = ["project", "env", "owner"]
}

variable "policy_deny_public_ip" {
  type        = bool
  description = "When true (default), assign the built-in policy that denies public IPs on network interfaces. Set false only if the workload genuinely needs NIC-level public IPs (e.g. compute_enable_public_ip = true for Listening Tentacles)."
  default     = true
}

variable "policy_require_disk_encryption" {
  type        = bool
  description = "When true (default), assign the built-in AUDIT policy for VMs missing Azure Disk Encryption / EncryptionAtHost. Audit (not deny) by design: managed disks are always encrypted at rest with platform keys; this surfaces VMs without the additional in-guest/host encryption layer."
  default     = true
}
