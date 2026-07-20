###############################################################################
# network.tf  --  MSMF Golden-Image PoC | Stage 2a (Network)
#
# Builds the landing-zone network the golden-image VMs deploy into:
#   * Resource group                     (AVM: avm-res-resources-resourcegroup)
#   * Virtual network + app/mgmt subnets (AVM: avm-res-network-virtualnetwork)
#   * Two subnet NSGs with tight rules   (AVM: avm-res-network-networksecuritygroup)
#
# Composition strategy (per PoC owner requirement "use Azure Verified Modules
# wherever practical"): every resource here maps to an official AVM module from
# the Terraform Registry, pinned to its 0.x major. No suitable-AVM gaps exist
# for this stage, so there is no raw-azurerm fallback. For reproducible builds,
# run `terraform init`, then pin the exact resolved versions and commit
# .terraform.lock.hcl.
#
# Security posture baked in here:
#   * RDP (3389) only from an explicit mgmt CIDR -- Internet exposure is blocked
#     by a variable validation, not just convention.
#   * HTTPS (443) to the app subnet from a configurable source; plain HTTP (80)
#     is OFF by default and only created when app_enable_http = true (opt-in).
#   * Octopus Tentacle listening port (10933) only from the Octopus Server CIDR.
#   * App-subnet RDP reachable only from the mgmt subnet (jump-host pattern).
#   * Azure Load Balancer health probes allowed (needed for VMSS/LB scenarios).
#   * An explicit Deny-All-Inbound backstop at priority 4096 on both subnets.
###############################################################################

# --------------------------------------------------------------------------- #
# Local naming + derived values.
# (local.common_tags is defined once in providers.tf and reused everywhere.)
# --------------------------------------------------------------------------- #
locals {
  name_suffix = "${var.project_name}-${var.environment}"

  rg_name          = coalesce(var.resource_group_name, "rg-${local.name_suffix}")
  vnet_name        = "vnet-${local.name_suffix}"
  app_subnet_name  = "snet-app-${var.environment}"
  mgmt_subnet_name = "snet-mgmt-${var.environment}"
  nsg_app_name     = "nsg-app-${var.environment}"
  nsg_mgmt_name    = "nsg-mgmt-${var.environment}"

  # ------------------------------------------------------------------------- #
  # NSG rule sets. Keyed maps (not lists) so a rule can be added/removed later
  # without renumbering everything. `name` is the Azure rule name; the map key
  # is the module's for_each key. Priorities are unique per direction.
  # ------------------------------------------------------------------------- #

  # Plain-HTTP (80) is OFF by default -- HTTPS-only posture. The allow_http
  # rule only exists when an operator opts in via var.app_enable_http = true
  # (see the variable's docs for the accepted use cases).
  app_nsg_rules = merge(
    var.app_enable_http ? {
      allow_http = {
        name                       = "Allow-HTTP-Inbound"
        priority                   = 100
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "80"
        source_address_prefix      = var.app_http_source_prefix
        destination_address_prefix = "*"
        description                = "HTTP to IIS on the application subnet (opt-in via app_enable_http)."
      }
    } : {},
    {
    allow_https = {
      name                       = "Allow-HTTPS-Inbound"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefix      = var.app_http_source_prefix
      destination_address_prefix = "*"
      description                = "HTTPS to IIS on the application subnet."
    }
    allow_octopus_tentacle = {
      name                       = "Allow-Octopus-Tentacle-10933-Inbound"
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "10933"
      source_address_prefixes    = var.octopus_server_source_cidrs
      destination_address_prefix = "*"
      description                = "Octopus Server -> Listening Tentacle (10933). Unused for Polling Tentacles."
    }
    allow_rdp_from_mgmt = {
      name                       = "Allow-RDP-From-Mgmt-Inbound"
      priority                   = 300
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefixes    = var.mgmt_subnet_address_prefixes
      destination_address_prefix = "*"
      description                = "RDP to app VMs only via the management subnet (jump-host pattern)."
    }
    allow_azure_lb = {
      name                       = "Allow-AzureLoadBalancer-Inbound"
      priority                   = 310
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "AzureLoadBalancer"
      destination_address_prefix = "*"
      description                = "Allow Azure Load Balancer health probes (VMSS / LB front ends)."
    }
    deny_all_inbound = {
      name                       = "Deny-All-Inbound"
      priority                   = 4096
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
      description                = "Explicit deny backstop (defense-in-depth; NSG default-deny is implicit)."
    }
  })

  mgmt_nsg_rules = {
    allow_rdp = {
      name                       = "Allow-RDP-Inbound"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefixes    = var.mgmt_rdp_source_cidrs
      destination_address_prefix = "*"
      description                = "RDP to the management subnet from approved corporate/VPN CIDRs only."
    }
    allow_octopus_tentacle = {
      name                       = "Allow-Octopus-Tentacle-10933-Inbound"
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "10933"
      source_address_prefixes    = var.octopus_server_source_cidrs
      destination_address_prefix = "*"
      description                = "Octopus Server -> Listening Tentacle (10933) on a managed jump host. Optional."
    }
    allow_azure_lb = {
      name                       = "Allow-AzureLoadBalancer-Inbound"
      priority                   = 300
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "AzureLoadBalancer"
      destination_address_prefix = "*"
      description                = "Allow Azure Load Balancer health probes."
    }
    deny_all_inbound = {
      name                       = "Deny-All-Inbound"
      priority                   = 4096
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
      description                = "Explicit deny backstop (defense-in-depth)."
    }
  }
}

# --------------------------------------------------------------------------- #
# Resource group
# AVM: Azure/avm-res-resources-resourcegroup/azurerm
# --------------------------------------------------------------------------- #
module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = ">= 0.1.0, < 1.0.0"

  name             = local.rg_name
  location         = var.location
  tags             = local.common_tags
  enable_telemetry = var.enable_telemetry
}

# --------------------------------------------------------------------------- #
# Application-subnet NSG
# AVM: Azure/avm-res-network-networksecuritygroup/azurerm
# --------------------------------------------------------------------------- #
module "nsg_app" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = ">= 0.2.0, < 1.0.0"

  name                = local.nsg_app_name
  resource_group_name = module.resource_group.name
  location            = var.location
  security_rules      = local.app_nsg_rules
  tags                = local.common_tags
  enable_telemetry    = var.enable_telemetry
}

# --------------------------------------------------------------------------- #
# Management-subnet NSG
# AVM: Azure/avm-res-network-networksecuritygroup/azurerm
# --------------------------------------------------------------------------- #
module "nsg_mgmt" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = ">= 0.2.0, < 1.0.0"

  name                = local.nsg_mgmt_name
  resource_group_name = module.resource_group.name
  location            = var.location
  security_rules      = local.mgmt_nsg_rules
  tags                = local.common_tags
  enable_telemetry    = var.enable_telemetry
}

# --------------------------------------------------------------------------- #
# Virtual network + subnets (with NSG associations)
# AVM: Azure/avm-res-network-virtualnetwork/azurerm
#
# The module creates the subnets inline and associates each NSG by resource_id,
# so no separate azurerm_subnet_network_security_group_association is needed.
#
# NOTE on egress: we keep the platform default outbound access (module default)
# so build/first-boot VMs can reach Octopus, package feeds and Azure endpoints.
# Azure is retiring implicit outbound access (Sept 2025); for production, add an
# explicit NAT Gateway (AVM: avm-res-network-natgateway) and set
# `default_outbound_access_enabled = false` on each subnet below.
# --------------------------------------------------------------------------- #
module "vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = ">= 0.4.0, < 1.0.0"

  name                = local.vnet_name
  resource_group_name = module.resource_group.name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = local.common_tags
  enable_telemetry    = var.enable_telemetry

  subnets = {
    app = {
      name             = local.app_subnet_name
      address_prefixes = var.app_subnet_address_prefixes
      network_security_group = {
        id = module.nsg_app.resource_id
      }
    }
    mgmt = {
      name             = local.mgmt_subnet_name
      address_prefixes = var.mgmt_subnet_address_prefixes
      network_security_group = {
        id = module.nsg_mgmt.resource_id
      }
    }
  }
}

###############################################################################
# Outputs -- consumed by the Compute stage (subnet IDs), the Policy stage
# (RG scope), and by operators. Output names are network-scoped to avoid
# collisions with other stages' outputs.
###############################################################################

output "resource_group_name" {
  description = "Name of the workload resource group."
  value       = module.resource_group.name
}

output "resource_group_id" {
  description = "Full resource ID of the workload resource group (use as a policy assignment scope)."
  value       = module.resource_group.resource_id
}

output "location" {
  description = "Azure region the network was deployed to."
  value       = var.location
}

output "vnet_id" {
  description = "Resource ID of the virtual network."
  value       = module.vnet.resource_id
}

output "vnet_name" {
  description = "Name of the virtual network."
  value       = module.vnet.name
}

output "app_subnet_id" {
  description = "Resource ID of the application subnet (attach VM/VMSS NICs here)."
  value       = module.vnet.subnets["app"].resource_id
}

output "mgmt_subnet_id" {
  description = "Resource ID of the management subnet (jump host / bastion)."
  value       = module.vnet.subnets["mgmt"].resource_id
}

output "nsg_app_id" {
  description = "Resource ID of the application-subnet NSG."
  value       = module.nsg_app.resource_id
}

output "nsg_mgmt_id" {
  description = "Resource ID of the management-subnet NSG."
  value       = module.nsg_mgmt.resource_id
}
