# Stage 1 — Golden Image Build (Packer)

Builds a **Windows Server 2022 (Gen2)** golden image with **IIS** and the
**Octopus Deploy Tentacle** baked in, and publishes it as an **image version**
inside an **Azure Compute Gallery** (Shared Image Gallery). Stage 2 (Terraform
compute) deploys VMs/VMSS from this image version; Stage 3 wires the deployed
machines to Octopus and CI/CD.

```
msmf-golden-image-poc/
├── packer/
│   ├── windows-golden-image.pkr.hcl            # azure-arm builder -> Compute Gallery
│   ├── variables.pkr.hcl                       # all inputs (secrets marked sensitive)
│   └── windows-golden-image.pkrvars.hcl.example
└── scripts/
    ├── 00-prereq-gallery.ps1                   # creates gallery + image definition (idempotent)
    ├── install-iis.ps1                         # IIS + common web features + health page
    └── install-octopus-tentacle.ps1            # Tentacle install/configure/register (idempotent)
```

## What gets baked in

| Component | Detail |
|-----------|--------|
| OS | Windows Server 2022 Datacenter, Gen2, generalized (Sysprep) |
| IIS | `Web-Server`, `Web-Mgmt-Tools`, `Web-Asp-Net45`, `Web-Net-Ext45`, compression, logging, request filtering, Windows auth, IIS PowerShell |
| Landing page | Branded `index.html` + `/health.html` (returns `OK`) for LB/App Gateway probes |
| Octopus Tentacle | MSI downloaded, **SHA256-verified when `tentacle_msi_sha256` is set** (build fails on mismatch; empty hash = warn only), installed, and script staged. **Registration is deferred to first boot by default** (see below). |
| Tags | `project=msmf-golden-image`, `env`, `owner` (+ `extra_tags`) on the build VM and the image version |

### Why Tentacle registration is deferred (important)

A generalized image is cloned to many VMs. If the Tentacle **certificate** and
**registration** were baked in, every clone would share one identity and collide
in Octopus. So the default build (`octopus_register_during_build = false`) only
**installs** the MSI and **stages** `install-octopus-tentacle.ps1` into the image
at `C:\ProgramData\msmf-golden-image\`. **Stage 2** runs that same script on first
boot (`-RegisterWithServer:$true`), so each VM generates a **unique certificate**
and registers itself with the correct roles/environment.

For a quick single-VM demo you can flip `octopus_register_during_build = true` to
register during the build — the capability is fully implemented — but do not use
that for a multi-VM golden image.

## Prerequisites

- **Packer ≥ 1.9** and the `azure` plugin (installed by `packer init`).
- **Azure CLI** logged in (`az login`) or a **service principal** with rights to
  create a build VM/resources and to write to the Compute Gallery
  (`Contributor` on the build RG + the gallery RG is sufficient for the PoC).
- An existing **Compute Gallery** and **image definition** (Generalized, Gen2).
  Create them with the helper (or let Stage-2 Terraform own them):

  ```powershell
  ./scripts/00-prereq-gallery.ps1 `
      -ResourceGroup rg-msmf-gallery `
      -GalleryName   gal_msmf `
      -Location      eastus `
      -ImageDefinition win2022-iis-octopus
  ```

## Configure

```bash
cd packer
cp windows-golden-image.pkrvars.hcl.example windows-golden-image.pkrvars.hcl
# edit gallery_* and (optionally) octopus_* values
```

For production images, pin the Tentacle download and its checksum so the build
fails hard if the MSI is ever tampered with (empty hash = install with a
warning only):

```hcl
tentacle_download_url = "https://download.octopusdeploy.com/octopus/Octopus.Tentacle.<version>-x64.msi"
tentacle_msi_sha256   = "<sha256-of-that-msi>"
```

Keep secrets out of the file — pass them as environment variables:

```bash
export PKR_VAR_client_secret='<sp-secret>'          # if using a service principal
export PKR_VAR_octopus_api_key='API-XXXXXXXXXXXX'   # only if registering during build
```

> In CI these come from **Azure Key Vault** / **Octopus sensitive variables**, never
> from source control. Add `*.pkrvars.hcl` to `.gitignore`.

## Build & publish

```bash
cd packer

# 1. Download the azure plugin declared in the template.
packer init .

# 2. Validate template + variables.
packer validate -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl

# 3. Build the image and publish the version into the gallery (~30–45 min).
packer build -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl
```

Packer will: create a temporary build VM from the marketplace base image → run
`install-iis.ps1` → reboot → run `install-octopus-tentacle.ps1` → **Sysprep
/generalize** → capture the generalized image as
`gallery_name / image_definition_name / image_version` → tear down the build VM
and temporary resource group. A `packer-build-manifest.json` is written for
traceability.

### Verify the published version

```bash
az sig image-version show \
  --resource-group rg-msmf-gallery \
  --gallery-name gal_msmf \
  --gallery-image-definition win2022-iis-octopus \
  --gallery-image-version 1.0.0 \
  --query "{state:provisioningState, regions:publishingProfile.targetRegions[].name}"
```

The full resource ID this produces is what **Stage 2** consumes as
`source_image_id` (or via `image_source = "gallery"`):

```
/subscriptions/<sub>/resourceGroups/rg-msmf-gallery/providers/Microsoft.Compute/galleries/gal_msmf/images/win2022-iis-octopus/versions/1.0.0
```

## Re-building a new version

Bump `image_version` (e.g. `1.0.1`) and re-run `packer build`. Each build is a new,
immutable gallery version; roll back by pointing Stage 2 at an earlier version.

## Notes on consistency with the other stages

- Packer uses its **own** HCL variable system (`variables.pkr.hcl`), independent of
  the Terraform `variables.tf` used by Stages 2/3 — no namespace collision. Shared
  values (region, gallery name/RG, image definition, Octopus URL) are named
  identically so they can be sourced from the same tfvars/pipeline variables.
  The image definition default `win2022-iis-octopus` matches the compute stage's
  `compute_image_definition_name` default.
- Secrets (`client_secret`, `octopus_api_key`) are `sensitive = true` and expected
  from Key Vault / Octopus, matching the "secrets out of code" rule for the PoC.
