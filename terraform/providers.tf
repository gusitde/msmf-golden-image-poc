###############################################################################
# providers.tf  --  SHARED across ALL Terraform stages of the
#                   "MS Migration Factory - Golden Image Prep" PoC.
#
# This file is authored once (by the Network stage) and consumed by every
# other stage (Compute, Octopus/CI-CD, Policy). Other stage authors add their
# own resource/variable files -- they DO NOT redeclare the terraform{},
# provider{}, or the shared locals{} blocks below.
#
# What lives here:
#   * required_version + required_providers (azurerm 4.x, octopusdeploy)
#   * remote-state backend stub (commented; wire it up per environment)
#   * the azurerm and octopusdeploy provider configurations
#   * local.common_tags -- the single, canonical tag map every resource uses
#
# Provider/plumbing variables (subscription_id, octopus_*, project_name, ...)
# are declared in variables.tf, which is also shared.
###############################################################################

terraform {
  # >= 1.10 because of the pinned AVM modules: the compute module
  # (Azure/avm-res-compute-virtualmachine v0.21.0) itself requires
  # Terraform >= 1.10, and the other avm-res-* modules need >= 1.9 for full
  # `optional()` object support. Declaring the real floor HERE makes a
  # too-old CLI fail fast at the root instead of deep inside a module.
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # Used by the Octopus / CI-CD stage to model environments, projects,
    # lifecycles and deployment targets. Declared here so it is available
    # cluster-wide; the Octopus stage author owns the resources.
    octopusdeploy = {
      source = "OctopusDeployLabs/octopusdeploy"
      # Kept intentionally permissive across the 0.x line (and into a future
      # 1.x) so `init` never fails for the Network-only path, which uses no
      # Octopus resources. The Octopus stage should pin this exactly and commit
      # the .terraform.lock.hcl.
      version = ">= 0.21.0, < 2.0.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state backend (STUB -- intentionally commented).
  # For a real deployment, create the state storage once (out of band), then
  # uncomment and run `terraform init -reconfigure`. Never commit real values
  # for a non-shared subscription; parameterize via `-backend-config`.
  # ---------------------------------------------------------------------------
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate-msmf"
  #   storage_account_name = "sttfstatemsmf"      # 3-24 lowercase, globally unique
  #   container_name       = "tfstate"
  #   key                  = "msmf-golden-image.tfstate"
  #   use_azuread_auth     = true                 # RBAC on the state container
  # }
}

###############################################################################
# Azure Resource Manager provider
#
# azurerm 4.x requires an explicit subscription. We pass it from a variable;
# when the variable is null (its default) the provider falls back to the
# ARM_SUBSCRIPTION_ID environment variable / Azure CLI context. Same for tenant.
###############################################################################
provider "azurerm" {
  features {}

  subscription_id = var.subscription_id # null => ARM_SUBSCRIPTION_ID / az CLI
  tenant_id       = var.tenant_id       # null => ARM_TENANT_ID / az CLI
}

###############################################################################
# Octopus Deploy provider
#
# Only initialized when a resource/data source of this provider is present in
# the plan (Terraform configures providers lazily). EVERY octopusdeploy
# resource/data source in this root is gated on var.enable_octopus_stage
# (default false), so network + compute plan/apply cleanly with the
# placeholder defaults below and NO reachable Octopus server. Flip
# enable_octopus_stage = true AND supply real octopus_server_url /
# TF_VAR_octopus_api_key (Key Vault or a pipeline secret) to manage Stage 3.
###############################################################################
provider "octopusdeploy" {
  address  = var.octopus_server_url
  api_key  = var.octopus_api_key
  space_id = var.octopus_space_id
}

###############################################################################
# Shared tags -- declared ONCE for the whole root module.
#
# Every resource in every stage sets `tags = local.common_tags` (merged with
# any resource-specific tags). Do not redeclare `common_tags` in another file;
# duplicate local names across files are a Terraform error.
#
# Baseline keys required by the PoC brief: project / env / owner.
###############################################################################
locals {
  common_tags = merge(
    {
      project    = var.project_name # "msmf-golden-image"
      env        = var.environment  # dev | test | prod
      owner      = var.owner
      managed_by = "terraform"
      workload   = "ms-migration-factory"
    },
    var.tags, # caller-supplied extras (cost-center, ticket, etc.)
  )
}
