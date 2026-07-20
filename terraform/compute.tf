###############################################################################
# MS Migration Factory — Golden Image Prep
# Stage 2b : COMPUTE  (Windows VMs FROM the golden image)
# File     : terraform/compute.tf
#
# WHAT THIS FILE DOES
#   * Resolves the golden OS image from EITHER an Azure Compute Gallery
#     (Shared Image Gallery) image version OR a VHD pulled from JFrog
#     Artifactory (toggle: var.image_source = "gallery" | "jfrog").
#   * Creates N Windows Server VMs from that image in the application subnet,
#     using the official Azure Verified Module (AVM) for compute VMs.
#   * Each VM gets: a system-assigned managed identity, boot diagnostics,
#     a NIC (optional public IP) protected by the app-subnet NSG, and a
#     CustomScript extension that registers the baked-in Octopus Tentacle
#     into the correct Space / Environment / Role(s) on first boot.
#
# INTEGRATION WITH THE OTHER STAGES (single root module under ./terraform)
#   * providers.tf (Network stage) owns terraform{}, provider{} and
#     `local.common_tags`. This file MERGES onto local.common_tags.
#   * network.tf (Stage 2a) creates `module.resource_group` and `module.vnet`
#     (subnets keyed "app"/"mgmt"). This file attaches VMs to
#     module.vnet.subnets["app"] inside module.resource_group by default.
#   * variables.tf (shared) declares: location, environment, owner,
#     project_name, resource_group_name, enable_telemetry, octopus_server_url,
#     octopus_api_key, octopus_space_id. This file consumes those and adds only
#     `compute_*` / `jfrog_*` inputs plus the `image_source` toggle it owns.
#
# PROVIDER / VERSION NOTES
#   The pinned AVM compute module (v0.21.0) requires terraform >= 1.10 and
#   azurerm >= 3.116, < 5.0 — both satisfied by providers.tf (azurerm ~> 4.0;
#   "use the latest 1.x"). It also pulls azapi/tls/modtm/random transitively;
#   none need a provider block in the root. `terraform_data` (JFrog import) is
#   built-in — no extra provider.
###############################################################################

#-----------------------------------------------------------------------------#
# Locals (namespaced to avoid collisions with other stages' locals)
#-----------------------------------------------------------------------------#
locals {
  # Canonical tag map (from providers.tf) + compute-specific tags.
  compute_tags = merge(
    local.common_tags,
    {
      component = "compute"
      stage     = "2b-compute"
    },
    var.compute_additional_tags,
  )

  # Resource groups. Default to the workload RG created by the network stage;
  # allow overrides (e.g. a dedicated shared "images" RG for the gallery).
  compute_app_rg     = coalesce(var.compute_resource_group_name, module.resource_group.name)
  compute_gallery_rg = coalesce(var.compute_gallery_resource_group_name, module.resource_group.name)
  jfrog_staging_rg   = coalesce(var.jfrog_staging_resource_group_name, module.resource_group.name)

  # Application subnet: default to the network stage's app subnet; allow an
  # explicit id override (e.g. an existing/peered network).
  compute_app_subnet_id = coalesce(var.compute_subnet_id, module.vnet.subnets["app"].resource_id)

  # Final OS image id handed to the VM module — gallery version OR the managed
  # image built from the JFrog VHD.
  compute_source_image_id = (
    var.image_source == "gallery"
    ? one(data.azurerm_shared_image_version.golden[*].id)
    : one(azurerm_image.jfrog[*].id)
  )

  # JFrog: deterministic page-blob URI the managed image is built from.
  jfrog_vhd_blob_uri = "https://${var.jfrog_staging_storage_account_name}.blob.core.windows.net/${var.jfrog_staging_container}/${var.jfrog_vhd_blob_name}"

  # When no admin password is supplied, let the module generate one
  # (store it in Key Vault in production — see account_credentials note below).
  compute_generate_admin_password = var.compute_admin_password == null

  # Octopus environment to register into. SINGLE SOURCE OF TRUTH with Stage 3:
  # the shared env (dev/test/prod) maps onto the SAME octopus_*_environment_name
  # variables that octopus.tf uses to create the environments, so out of the
  # box a `dev` deployment registers into "Development" (an environment Stage 3
  # actually creates). var.compute_octopus_environment overrides the mapping
  # only for non-standard setups.
  compute_octopus_env_by_environment = {
    dev  = var.octopus_dev_environment_name
    test = var.octopus_test_environment_name
    prod = var.octopus_prod_environment_name
  }
  compute_octopus_env = coalesce(var.compute_octopus_environment, local.compute_octopus_env_by_environment[var.environment])

  # Map of VM instances -> config. Zones are round-robined across the pool.
  compute_vm_instances = {
    for i in range(var.compute_vm_count) :
    format("%s-%02d", var.compute_vm_name_prefix, i + 1) => {
      zone = element(var.compute_availability_zones, i % length(var.compute_availability_zones))
    }
  }

  #---------------------------------------------------------------------------#
  # Octopus Tentacle bootstrap command (runs via the CustomScript extension).
  #
  # The registration PowerShell script is read from disk and base64-encoded
  # (UTF-8). The one-liner below decodes it to a file on the VM and executes
  # it.
  #
  # SECRET HANDLING (deliberate, reviewed):
  #   * The ENTIRE command - including `-ApiKey '<octopus_api_key>'` - is
  #     placed EXCLUSIVELY in the extension's `protected_settings`
  #     (`commandToExecute`), which Azure encrypts at rest and never returns
  #     via the portal/CLI/ARM API. Nothing derived from the API key may
  #     appear in the PLAIN `settings` block - the re-run trigger hash there
  #     is computed from the script + non-secret args ONLY (see the
  #     extension block below).
  #   * The API key is passed only as a runtime parameter so it is never
  #     written into the script file on the VM's disk, and the register
  #     script masks it in its transcripts.
  #   * RESIDUAL RISK + PRODUCTION ALTERNATIVE: protected_settings still
  #     lands in Terraform STATE (see "State hygiene" in the README - use an
  #     encrypted remote backend and rotate the key after provisioning). To
  #     keep the key out of state AND out of the extension entirely, the
  #     recommended production pattern is a Key-Vault pull inside the VM:
  #     grant each VM's system-assigned managed identity (created below,
  #     principal ids exported in outputs.compute.tf) `Key Vault Secrets
  #     User` on a vault holding the Octopus API key, and have the command
  #     fetch it at boot instead of receiving it, e.g.:
  #       $t = Invoke-RestMethod -Headers @{Metadata='true'} -Uri `
  #         'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net'
  #       $k = (Invoke-RestMethod -Headers @{Authorization="Bearer $($t.access_token)"} -Uri `
  #         'https://<vault>.vault.azure.net/secrets/octopus-api-key?api-version=7.4').value
  #       & $f <args> -ApiKey $k
  #     Then Terraform never touches the secret and rotation is a vault-only
  #     operation. Kept out of the default path only to keep the PoC free of
  #     a hard Key Vault dependency.
  #
  # NOTE ON `${}` : this inline string uses ONLY $env:/$d/$f (no PowerShell
  # `${}`), so Terraform's `${...}` interpolation cannot collide with it. The
  # .ps1 itself is read with file() (not templatefile), so it may use any
  # PowerShell syntax freely.
  #---------------------------------------------------------------------------#
  compute_tentacle_script_b64 = base64encode(file("${path.module}/../scripts/register-octopus-tentacle.ps1"))

  compute_tentacle_args = join(" ", compact([
    "-OctopusServerUrl '${var.octopus_server_url}'",
    "-Space '${var.compute_octopus_space_name}'",
    "-Environment '${local.compute_octopus_env}'",
    "-Roles '${join(",", var.compute_octopus_target_roles)}'",
    "-CommsStyle '${var.compute_octopus_comms_style}'",
    "-ListenPort ${var.compute_octopus_listen_port}",
    "-ServerCommsPort ${var.compute_octopus_polling_port}",
    "-InstanceName '${var.compute_tentacle_instance_name}'",
    "-ApplicationsDirectory '${var.compute_tentacle_applications_dir}'",
    "-MachinePolicy '${var.compute_octopus_machine_policy}'",
    var.compute_octopus_server_thumbprint == null ? "" : "-ServerThumbprint '${var.compute_octopus_server_thumbprint}'",
  ]))

  compute_octopus_register_command = join(" ", [
    "powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -Command",
    "\"$ErrorActionPreference='Stop';",
    "$d=Join-Path $env:ProgramData 'msmf-bootstrap';",
    "New-Item -ItemType Directory -Force -Path $d | Out-Null;",
    "$f=Join-Path $d 'register-octopus-tentacle.ps1';",
    "[IO.File]::WriteAllText($f,[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${local.compute_tentacle_script_b64}')));",
    "& $f ${local.compute_tentacle_args} -ApiKey '${var.octopus_api_key}' -MachineName $env:COMPUTERNAME\"",
  ])
}

#-----------------------------------------------------------------------------#
# Image source A — Azure Compute Gallery (Shared Image Gallery) image version.
# Built by Stage 1 (Packer azure-arm builder). "latest"/"recent" are accepted
# by the data source `name` argument.
#-----------------------------------------------------------------------------#
data "azurerm_shared_image_version" "golden" {
  count = var.image_source == "gallery" ? 1 : 0

  name                = var.compute_image_version
  image_name          = var.compute_image_definition_name
  gallery_name        = var.compute_compute_gallery_name
  resource_group_name = local.compute_gallery_rg
}

#-----------------------------------------------------------------------------#
# Image source B — JFrog Artifactory VHD -> managed image.
#
# Terraform cannot natively stream a VHD out of Artifactory, so a helper script
# (scripts/import-jfrog-vhd.ps1) pulls the VHD and uploads it as a PAGE blob
# into a staging storage account. `azurerm_image` then wraps that blob as a
# generalized Windows managed image the VMs boot from. Credentials are passed
# via environment variables (never on the command line / in state).
#
# NOTE: no suitable AVM exists for "import an external VHD into a managed
# image", so raw azurerm_image + terraform_data is used here by design.
#-----------------------------------------------------------------------------#
resource "terraform_data" "jfrog_vhd_import" {
  count = var.image_source == "jfrog" ? 1 : 0

  # Re-run the import whenever the source, destination or blob name changes.
  triggers_replace = {
    source_url           = "${var.jfrog_base_url}/${var.jfrog_repo_path}"
    destination_blob     = var.jfrog_vhd_blob_name
    storage_account_name = var.jfrog_staging_storage_account_name
    container            = var.jfrog_staging_container
  }

  provisioner "local-exec" {
    # Requires PowerShell 7 (pwsh) + Azure CLI on the runner (CI agent).
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
    command = join(" ", [
      "& '${path.module}/../scripts/import-jfrog-vhd.ps1'",
      "-SourceUrl '${var.jfrog_base_url}/${var.jfrog_repo_path}'",
      "-ResourceGroup '${local.jfrog_staging_rg}'",
      "-StorageAccount '${var.jfrog_staging_storage_account_name}'",
      "-Container '${var.jfrog_staging_container}'",
      "-BlobName '${var.jfrog_vhd_blob_name}'",
    ])
    environment = {
      JFROG_USERNAME     = var.jfrog_username
      JFROG_PASSWORD     = var.jfrog_password
      JFROG_ACCESS_TOKEN = var.jfrog_access_token
    }
  }
}

resource "azurerm_image" "jfrog" {
  count = var.image_source == "jfrog" ? 1 : 0

  name                = "${var.compute_vm_name_prefix}-golden-jfrog"
  location            = var.location
  resource_group_name = local.compute_gallery_rg
  hyper_v_generation  = var.compute_image_hyper_v_generation

  os_disk {
    os_type      = "Windows"
    os_state     = "Generalized"
    storage_type = "StandardSSD_LRS"
    blob_uri = local.jfrog_vhd_blob_uri
    caching  = "ReadWrite"
    size_gb  = var.compute_jfrog_os_disk_size_gb
  }

  tags       = local.compute_tags
  depends_on = [terraform_data.jfrog_vhd_import]
}

#-----------------------------------------------------------------------------#
# Compute — N Windows VMs from the golden image (Azure Verified Module).
# Module: Azure/avm-res-compute-virtualmachine/azurerm (pinned).
#-----------------------------------------------------------------------------#
module "vm" {
  source   = "Azure/avm-res-compute-virtualmachine/azurerm"
  version  = "0.21.0"
  for_each = local.compute_vm_instances

  name                = each.key
  resource_group_name = local.compute_app_rg
  location            = var.location
  zone                = each.value.zone
  os_type             = "Windows"
  sku_size            = var.compute_vm_size
  enable_telemetry    = var.enable_telemetry

  # Golden image (gallery version id OR JFrog-derived managed image id).
  source_image_resource_id = local.compute_source_image_id

  # Local administrator. Supply a password via TF_VAR_compute_admin_password
  # (or a Key Vault-sourced secret). Leave it null to let the module generate
  # one; in production add `key_vault_configuration` to persist it securely.
  # STATE NOTE: either way the resolved password is persisted in Terraform
  # state (module-generated included) - see "State hygiene" in the README:
  # encrypted remote backend only, and rotate anything that passed through a
  # local/demo state file.
  account_credentials = {
    admin_credentials = {
      username                           = var.compute_admin_username
      password                           = var.compute_admin_password
      generate_admin_password_or_ssh_key = local.compute_generate_admin_password
    }
  }

  # System-assigned managed identity (principal id exported below).
  managed_identities = {
    system_assigned = true
  }

  # Managed-storage boot diagnostics unless an explicit endpoint is provided.
  boot_diagnostics                     = true
  boot_diagnostics_storage_account_uri = var.compute_boot_diagnostics_storage_uri

  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = var.compute_os_disk_storage_account_type
  }

  # Single NIC in the app subnet, optional public IP. The NIC/public IP sit
  # behind the app-subnet NSG owned by the network stage (Stage 2a).
  network_interfaces = {
    primary = {
      name = "${each.key}-nic"
      ip_configurations = {
        ipconfig1 = {
          name                          = "${each.key}-ipcfg1"
          private_ip_subnet_resource_id = local.compute_app_subnet_id
          create_public_ip_address      = var.compute_enable_public_ip
          public_ip_address_name        = var.compute_enable_public_ip ? "${each.key}-pip" : null
        }
      }
    }
  }

  # CustomScript extension: register the baked-in Octopus Tentacle on boot.
  # The WHOLE command (including -ApiKey) lives ONLY in protected_settings
  # (encrypted at rest, not readable back via portal/CLI/ARM). The re-run
  # trigger hash in the PLAIN `settings` block is deliberately computed from
  # the script + non-secret args only - compute_tentacle_args excludes the
  # API key - so no secret-derived material ever appears unencrypted.
  extensions = {
    octopus_register = {
      name                       = "octopus-tentacle-register"
      publisher                  = "Microsoft.Compute"
      type                       = "CustomScriptExtension"
      type_handler_version       = "1.10"
      auto_upgrade_minor_version = true
      settings                   = jsonencode({ contentVersion = "1.0", scriptSha1 = sha1("${local.compute_tentacle_script_b64}|${local.compute_tentacle_args}") })
      protected_settings         = jsonencode({ commandToExecute = local.compute_octopus_register_command })
    }
  }

  tags = local.compute_tags

  depends_on = [
    data.azurerm_shared_image_version.golden,
    azurerm_image.jfrog,
  ]
}
