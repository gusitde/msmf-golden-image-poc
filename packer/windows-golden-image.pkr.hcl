# =============================================================================
# MS Migration Factory - Golden Image Prep
# Stage 1 : Golden Image Build (Packer / azure-arm)
# -----------------------------------------------------------------------------
# Builds a Windows Server 2022 (Gen2) golden image that ships with:
#   * IIS + common web features (see scripts/install-iis.ps1)
#   * Octopus Deploy Tentacle installed & staged (see scripts/install-octopus-tentacle.ps1)
# and publishes the result as an *image version* inside an Azure Compute Gallery
# (a.k.a. Shared Image Gallery / SIG) so Stage 2 (Terraform compute) can deploy
# VMs / VMSS directly from it.
#
# Build:
#   packer init  .
#   packer validate -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl
#   packer build    -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl
#
# The target Compute Gallery + image *definition* must exist before you build
# (Packer publishes an image *version* into an existing definition). Create them
# with scripts/00-prereq-gallery.ps1, or let Stage-2 Terraform own the gallery.
#
# Conventions shared with the wider PoC:
#   project = msmf-golden-image  (tag)
#   owner   / env are supplied via variables and applied as azure_tags
# =============================================================================

packer {
  required_version = ">= 1.9.0"

  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2.1"
    }

    # ---------------------------------------------------------------------------
    # OPTIONAL: patch the golden image during the build (recommended for prod).
    # Uncomment here AND the matching provisioner below, then re-run `packer init`.
    #
    # windows-update = {
    #   source  = "github.com/rgl/windows-update"
    #   version = "~> 0.16"
    # }
    # ---------------------------------------------------------------------------
  }
}

# -----------------------------------------------------------------------------
# Variable declarations live in variables.pkr.hcl (kept separate so the other
# PoC stages can drop their own *.tf variable files alongside without clashing).
# -----------------------------------------------------------------------------

# Locals: single source of truth for tags + a build timestamp used for
# traceability inside the image and on the gallery version.
locals {
  # timestamp() returns RFC 3339 UTC (e.g. 2026-07-19T13:56:00Z); evaluated once
  # per run and safe as an Azure tag value.
  build_timestamp = timestamp()

  common_tags = merge(
    {
      project    = "msmf-golden-image"
      env        = var.env
      owner      = var.owner
      stage      = "01-golden-image"
      os         = "WindowsServer2022"
      packer     = "true"
      built_utc  = local.build_timestamp
      base_image = "${var.image_publisher}:${var.image_offer}:${var.image_sku}"
    },
    var.extra_tags,
  )
}

# =============================================================================
# SOURCE: azure-arm builder -> generalized Windows image -> Compute Gallery
# =============================================================================
source "azure-arm" "windows" {

  # --- Authentication -------------------------------------------------------
  # Two supported modes (pick one; do not set both):
  #   1. Service principal  -> set client_id / client_secret / tenant_id
  #   2. Azure CLI          -> set use_azure_cli_auth = true (leave SP creds empty)
  # subscription_id is always required.
  subscription_id    = var.subscription_id
  tenant_id          = var.tenant_id
  client_id          = var.client_id
  client_secret      = var.client_secret
  use_azure_cli_auth = var.use_azure_cli_auth

  # --- Base (marketplace) image --------------------------------------------
  os_type         = "Windows"
  image_publisher = var.image_publisher
  image_offer     = var.image_offer
  image_sku       = var.image_sku
  image_version   = var.base_image_version # "latest" by default

  # --- Build VM sizing / placement -----------------------------------------
  location        = var.location
  vm_size         = var.vm_size
  os_disk_size_gb = var.os_disk_size_gb

  # By default (build_resource_group_name empty) Packer creates and tears down a
  # short-lived temporary resource group for the build VM. Set
  # build_resource_group_name to reuse an existing RG instead. Passing null here
  # leaves the attribute unset, which triggers the auto temp-RG behaviour.
  build_resource_group_name = var.build_resource_group_name == "" ? null : var.build_resource_group_name

  # --- Communicator: WinRM over HTTPS (self-signed cert managed by Packer) ---
  # winrm_insecure = true skips TLS certificate VALIDATION only - the channel
  # is still TLS-encrypted (winrm_use_ssl). This is the standard, accepted
  # setup for azure-arm builds: the cert is a per-build self-signed one Packer
  # itself generates for an EPHEMERAL build VM that lives minutes, in its own
  # temporary resource group, and is destroyed after capture - there is no CA
  # that could vouch for it. Residual risk is a MITM on the WinRM leg during
  # the build window; for hardened production pipelines run the build in an
  # isolated/private build subnet so that leg is never exposed.
  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "15m"
  winrm_username = "packer"

  # --- OUTPUT: publish an image *version* into an existing Compute Gallery ---
  # The image is captured GENERALIZED (we Sysprep in the final provisioner),
  # which is what SIG "Generalized" image definitions require.
  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.gallery_resource_group
    gallery_name         = var.gallery_name
    image_name           = var.image_definition_name
    image_version        = var.image_version
    replication_regions  = var.replication_regions
    storage_account_type = var.image_storage_account_type
  }

  # Keep the produced gallery version around (do not auto-delete intermediate
  # managed image; SIG publish handles the capture directly).
  azure_tags = local.common_tags
}

# =============================================================================
# BUILD: provisioners run in order against the temporary build VM
# =============================================================================
build {
  name    = "msmf-golden-image"
  sources = ["source.azure-arm.windows"]

  # ---------------------------------------------------------------------------
  # OPTIONAL: Windows Update pass (see plugin note above). Long-running.
  #
  # provisioner "windows-update" {
  #   search_criteria = "IsInstalled=0"
  #   filters = [
  #     "exclude:$_.Title -like '*Preview*'",
  #     "include:$true",
  #   ]
  #   update_limit = 25
  # }
  # ---------------------------------------------------------------------------

  # 1) Install + configure IIS and common web features, drop a health page.
  provisioner "powershell" {
    script           = "${path.root}/../scripts/install-iis.ps1"
    execution_policy = "bypass"
  }

  # 2) Reboot so IIS/service state is clean before we lay down the Tentacle.
  provisioner "windows-restart" {
    restart_timeout = "10m"
  }

  # 3) Install (and, if enabled, register) the Octopus Deploy Tentacle.
  #
  # GOLDEN-IMAGE BEST PRACTICE: by default we ONLY install the Tentacle MSI and
  # stage the registration script into the image; we do NOT create the Tentacle
  # instance/certificate or register during the build. Reason: a generalized
  # image is cloned to many VMs; if the certificate/registration were baked in,
  # every VM would share one identity and collide in Octopus. Stage-2 Terraform
  # runs this same script on first boot (via custom-script extension / cloud-init)
  # so each VM generates a unique certificate and registers itself.
  #
  # Set octopus_register_during_build = true to fully register at build time
  # (handy for a single-VM demo). Secrets are passed as environment variables and
  # never written into the template.
  provisioner "powershell" {
    script           = "${path.root}/../scripts/install-octopus-tentacle.ps1"
    execution_policy = "bypass"
    environment_vars = [
      "OCTOPUS_REGISTER_DURING_BUILD=${var.octopus_register_during_build ? "true" : "false"}",
      "OCTOPUS_SERVER_URL=${var.octopus_server_url}",
      "OCTOPUS_API_KEY=${var.octopus_api_key}",
      "OCTOPUS_SPACE=${var.octopus_space}",
      "OCTOPUS_ENVIRONMENT=${var.octopus_environment}",
      "OCTOPUS_ROLES=${join(",", var.octopus_roles)}",
      "OCTOPUS_COMMS_STYLE=${var.octopus_comms_style}",
      "OCTOPUS_LISTEN_PORT=${var.octopus_listen_port}",
      "OCTOPUS_SERVER_COMMS_PORT=${var.octopus_server_comms_port}",
      "OCTOPUS_TENTACLE_DOWNLOAD_URL=${var.tentacle_download_url}",
      "OCTOPUS_TENTACLE_MSI_SHA256=${var.tentacle_msi_sha256}",
      "OCTOPUS_INSTANCE_NAME=${var.octopus_instance_name}",
      "OCTOPUS_SERVER_THUMBPRINT=${var.octopus_server_thumbprint}",
    ]
  }

  # 4) Generalize (Sysprep). This must be the LAST step; after it completes the
  #    azure-arm builder captures the generalized image into the gallery.
  provisioner "powershell" {
    execution_policy = "bypass"
    inline = [
      "# Wait for the Azure guest agents to be running before generalize.",
      "Write-Host 'Waiting for Azure guest agents...'",
      "while ((Get-Service RdAgent -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Sleep -Seconds 5 }",
      "while ((Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Sleep -Seconds 5 }",
      "Write-Host 'Running Sysprep /generalize ...'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit /mode:vm",
      "# Block until the image has resealed to OOBE; abort on any error state.",
      "$stateKey = 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State'",
      "while ($true) {",
      "  $imageState = (Get-ItemProperty -Path $stateKey -Name ImageState -ErrorAction SilentlyContinue).ImageState",
      "  Write-Host \"ImageState = $imageState\"",
      "  if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }",
      "  if ($null -eq $imageState) { throw 'Sysprep did not produce an ImageState; check C:\\Windows\\System32\\Sysprep\\Panther logs.' }",
      "  Start-Sleep -Seconds 10",
      "}",
      "Write-Host 'Sysprep complete; image is generalized and ready for capture.'",
    ]
  }

  # 5) Human-readable + machine-readable build manifest for traceability.
  post-processor "manifest" {
    output     = "${path.root}/../packer-build-manifest.json"
    strip_path = true
    custom_data = {
      image_gallery      = var.gallery_name
      image_definition   = var.image_definition_name
      image_version      = var.image_version
      base_image         = "${var.image_publisher}:${var.image_offer}:${var.image_sku}"
      env                = var.env
      owner              = var.owner
      octopus_registered = var.octopus_register_during_build ? "true" : "false"
      built_utc          = local.build_timestamp
    }
  }
}
