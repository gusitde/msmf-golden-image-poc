# MS Migration Factory — Golden Image Prep · Deployment Guide

This is the step‑by‑step runbook for standing up the PoC end to end. It follows the three stages in the repository exactly:

1. **Stage 1 — Golden image (Packer):** build a generalized Windows Server 2022 image with IIS + an Octopus Tentacle baked in, and publish it as a version in an **Azure Compute Gallery**.
2. **Stage 2 — Azure infra (Terraform + Azure Verified Modules):** create the resource group, VNet/subnets/NSGs, the Azure Policy compliance baseline, and *N* Windows VMs **from the golden image** (image source toggle: gallery **or** JFrog).
3. **Stage 3 — Octopus + CI/CD:** create the Octopus environments, lifecycle, project and deployment process (gated behind `enable_octopus_stage`), then drive a Dev → Test → Prod promotion from a pipeline.

Everything is parameterized and no secrets live in code. Terraform is **one root module with one state file** under `terraform/`; the Octopus stage is isolated *logically* by the `enable_octopus_stage` flag, not by a separate state root.

> **Cross‑stage naming contract.** The gallery coordinates are shared defaults on *both* the Packer and Terraform sides and must be changed together or not at all:
> `rg-msmf-gallery` (resource group) / `gal_msmf` (gallery) / `win2022-iis-octopus` (image definition).
> Packer side: `gallery_resource_group` / `gallery_name` / `image_definition_name` in `packer/variables.pkr.hcl`.
> Terraform side: `compute_gallery_resource_group_name` / `compute_compute_gallery_name` / `compute_image_definition_name` in `terraform/variables.compute.tf`.

---

## 1. Prerequisites checklist

| Requirement | Version / detail |
|-------------|------------------|
| **Azure subscription + roles** | *Contributor* on the target subscription/RGs, plus **Resource Policy Contributor** (for `policy.tf` assignments) and **Managed Identity Operator** (VMs get a system‑assigned identity). |
| **Azure CLI** | `az` ≥ 2.60, signed in: `az login`, then `az account set --subscription <id>`. |
| **Packer** | ≥ 1.9 (`required_version = ">= 1.9.0"` in `windows-golden-image.pkr.hcl`). The `github.com/hashicorp/azure ~> 2.1` plugin is installed by `packer init`. |
| **Terraform** | **≥ 1.10.0** (`required_version` in `terraform/providers.tf`; the pinned AVM compute module `Azure/avm-res-compute-virtualmachine/azurerm 0.21.0` itself requires 1.10). |
| **azurerm provider** | `~> 4.0` (pinned in `providers.tf`). Note: azurerm 4.x needs an explicit subscription — provided via `subscription_id`, or `ARM_SUBSCRIPTION_ID`, or the `az` CLI context. |
| **octopusdeploy provider** | `OctopusDeployLabs/octopusdeploy >= 0.21.0, < 2.0.0` (permissive shared pin so `init` never fails for the network‑only path). Stage 3 is authored/verified against **0.43.x** — pin it (`~> 0.43`) and commit `.terraform.lock.hcl` for reproducible builds. |
| **Octopus Server** | Only when `enable_octopus_stage = true`. Octopus Cloud (`https://<you>.octopus.app`) or self‑hosted, reachable from Azure, with an **API key** (`API-…`) that can manage the target Space. |
| **JFrog Artifactory** | Only when `image_source = "jfrog"`: base URL, repo path to a generalized Windows VHD, and a read token (or username/password). The import runner needs **PowerShell 7 (`pwsh`)**, `az`, and native `curl` on PATH. |
| **.NET SDK** | 8.0.x — only on the CI agent that packages the sample app (`src/MSMF.GoldenImage.WebApp`, `net8.0`). The provided pipelines install it for you. |
| **Shell** | Terraform/Packer commands below are shown for bash; the helper `scripts/00-prereq-gallery.ps1`, `scripts/import-jfrog-vhd.ps1`, and the on‑VM scripts are PowerShell. |

**Authentication model.** Both Packer and Terraform default to the **Azure CLI session** (`az login`). For unattended CI, use a service principal:
- Terraform: `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`.
- Packer: `client_id` / `client_secret` / `tenant_id` / `subscription_id` (set `use_azure_cli_auth = false`), or set `use_azure_cli_auth = true` and leave the SP fields empty.

---

## 2. Secrets & variables checklist — *where each value lives*

**Golden rule:** non‑secret configuration → a `terraform.tfvars` you create (git‑ignored); secrets → **Key Vault / CI secret store**, surfaced as `TF_VAR_*` (Terraform) or `PKR_VAR_*` (Packer) at run time; **application runtime** secrets → **Octopus sensitive variables**. Never commit a secret to any `*.tfvars` / `*.pkrvars.hcl`.

The example files to copy from:

- `terraform/terraform.tfvars.example` — shared + network + policy inputs (includes `enable_octopus_stage`).
- `terraform/terraform.tfvars.compute.example` — Stage 2b `compute_*` / `jfrog_*` / `image_source`.
- `terraform/terraform.tfvars.octopus.example` — Stage 3 `octopus_*`.
- `packer/windows-golden-image.pkrvars.hcl.example` — Stage 1 (Packer).

The root‑level `terraform.tfvars.example` is a **pointer only** — the canonical examples are the three under `terraform/`.

### 2.1 Where each value belongs

| Value(s) | Lives in | Secret? |
|----------|----------|:-------:|
| `subscription_id`, `tenant_id` | `terraform.tfvars` **or** `ARM_*` env / `az` session (null → CLI/env) | no |
| `location`, `environment`, `owner`, `project_name`, `tags`, `enable_telemetry` | `terraform.tfvars` | no |
| Network: `resource_group_name`, `vnet_address_space`, `app_subnet_address_prefixes`, `mgmt_subnet_address_prefixes`, `mgmt_rdp_source_cidrs`, `app_http_source_prefix`, `app_enable_http`, `octopus_server_source_cidrs` | `terraform.tfvars` | no |
| Policy: `policy_enforcement_mode`, `policy_allowed_locations`, `policy_required_tag_keys`, `policy_deny_public_ip`, `policy_require_disk_encryption` | `terraform.tfvars` | no |
| Image source + gallery coords: `image_source`, `compute_compute_gallery_name`, `compute_image_definition_name`, `compute_image_version`, `compute_gallery_resource_group_name`, `compute_image_hyper_v_generation` | `terraform.tfvars` (keep identical to Packer) | no |
| Compute: `compute_vm_count`, `compute_vm_size`, `compute_vm_name_prefix`, `compute_availability_zones`, `compute_admin_username`, `compute_enable_public_ip`, `compute_os_disk_storage_account_type`, `compute_octopus_*` | `terraform.tfvars` | no |
| JFrog endpoint/staging: `jfrog_base_url`, `jfrog_repo_path`, `jfrog_staging_storage_account_name`, `jfrog_staging_resource_group_name`, `jfrog_staging_container`, `jfrog_vhd_blob_name`, `compute_jfrog_os_disk_size_gb` | `terraform.tfvars` | no |
| Octopus config: `enable_octopus_stage`, `octopus_server_url`, `octopus_space_id`, `octopus_*_environment_name`, `octopus_project_name`, `octopus_project_group_name`, `octopus_lifecycle_name`, `octopus_package_id`, `octopus_target_roles`, `octopus_iis_*` | `terraform.tfvars` | no |
| **`compute_admin_password`** | **Key Vault → `TF_VAR_compute_admin_password`** (or leave `null` to auto‑generate) | **yes** |
| **`octopus_api_key`** | **Key Vault / CI secret → `TF_VAR_octopus_api_key`** — never in tfvars | **yes** |
| **`jfrog_access_token`** (or `jfrog_username` / `jfrog_password`) | **Key Vault → `TF_VAR_jfrog_access_token`** | **yes** |
| **Packer** `client_secret`, `octopus_api_key` | env `PKR_VAR_client_secret` / `PKR_VAR_octopus_api_key` | **yes** |
| **Packer** `tentacle_msi_sha256`, `tentacle_download_url` | `*.pkrvars.hcl` (the hash is a non‑secret integrity pin) | no |
| **App** connection strings / API keys / cert passwords | **Octopus sensitive variables** (scoped per environment) | **yes** |

> Note the two distinct Octopus "space" inputs: the **provider** uses `octopus_space_id` (e.g. `Spaces-1`); the on‑VM **Tentacle registration** uses `compute_octopus_space_name` (a space *name*, default `Default`). They are independent — set both to the same Space.

### 2.2 Pulling secrets from Key Vault at run time

```bash
export TF_VAR_octopus_api_key=$(az keyvault secret show \
  --vault-name kv-msmf-secrets --name octopus-api-key --query value -o tsv)

export TF_VAR_compute_admin_password=$(az keyvault secret show \
  --vault-name kv-msmf-secrets --name vm-admin-password --query value -o tsv)

# JFrog path only:
export TF_VAR_jfrog_access_token=$(az keyvault secret show \
  --vault-name kv-msmf-secrets --name jfrog-access-token --query value -o tsv)
```

Add `terraform.tfvars`, `*.pkrvars.hcl`, `*.tfplan`, `.terraform/`, and `*.tfstate*` to `.gitignore`, and consider a pre‑commit secret scanner (e.g. gitleaks).

> **Marking `sensitive` does not encrypt state.** `octopus_api_key` and the admin password still land verbatim in `terraform.tfstate` (see §8). Use a remote encrypted backend for any non‑throwaway run.

---

## 3. Step 1 — Build the golden image (Packer → Compute Gallery)

Packer publishes an image **version** into an **existing** gallery image *definition*; it does not create the gallery. Create the gallery + definition once (idempotent), then build.

### 3.1 One‑time: create the gallery + image definition

```powershell
./scripts/00-prereq-gallery.ps1 `
    -ResourceGroup   rg-msmf-gallery `
    -GalleryName     gal_msmf `
    -Location        eastus `
    -ImageDefinition win2022-iis-octopus
```

This creates the RG, the Compute Gallery, and a **Generalized / Gen2** image definition — the exact coordinates Stage 2 later resolves. Re‑runs are safe.

### 3.2 Configure and build

```bash
cd packer
cp windows-golden-image.pkrvars.hcl.example windows-golden-image.pkrvars.hcl   # then edit

# secrets stay out of the file:
export PKR_VAR_client_secret='<sp-secret>'          # only for service-principal auth
# export PKR_VAR_octopus_api_key='API-XXXX...'      # only if octopus_register_during_build = true

packer init .
packer validate -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl
packer build    -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl   # ~30–45 min
```

**What the build does, in order** (see the `build` block in `windows-golden-image.pkr.hcl`):

1. Provisions a temporary build VM from the marketplace base (`MicrosoftWindowsServer:WindowsServer:2022-datacenter-g2`, `latest`).
2. Runs `scripts/install-iis.ps1` — installs the `Web-Server` role plus common web features (static content, compression, logging, request filtering, Windows auth, `Web-Asp-Net45` / .NET 4.x, IIS management + PowerShell), writes a branded `index.html` and a `/health.html` (returns `OK`), and smoke‑tests `http://localhost/health.html`.
3. `windows-restart`.
4. Runs `scripts/install-octopus-tentacle.ps1` — downloads the Tentacle MSI, **SHA256‑verifies it when `tentacle_msi_sha256` is set** (build fails hard on mismatch; empty hash warns only), installs it, and **stages** the registration script into `C:\ProgramData\msmf-golden-image\`. By default (`octopus_register_during_build = false`) it does **not** register — registration is deferred to first boot so every cloned VM gets a unique certificate.
5. Sysprep `/generalize` and waits for `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`, then the `azure-arm` builder captures the generalized image.
6. Writes `packer-build-manifest.json` for traceability.

### 3.3 What gets published

The `shared_image_gallery_destination` block publishes to (defaults from `packer/variables.pkr.hcl`):

- **Gallery resource group:** `gallery_resource_group = rg-msmf-gallery`
- **Gallery:** `gallery_name = gal_msmf`
- **Image definition:** `image_definition_name = win2022-iis-octopus`
- **Version:** `image_version = 1.0.0` (bump per build — must be `MAJOR.MINOR.PATCH`)
- **Replication:** `replication_regions` (example sets `["eastus","eastus2"]`)

Verify the version exists:

```bash
az sig image-version show \
  --resource-group rg-msmf-gallery --gallery-name gal_msmf \
  --gallery-image-definition win2022-iis-octopus --gallery-image-version 1.0.0 \
  --query "{state:provisioningState, regions:publishingProfile.targetRegions[].name}"
```

> **Supply‑chain pin (recommended for real images):** set `tentacle_download_url` to a specific version URL and `tentacle_msi_sha256` to its checksum.
>
> **Known PoC gap to note for ASP.NET Core:** `install-iis.ps1` installs ASP.NET **4.x**, not the **.NET Core Hosting Bundle** (ANCM). The sample app is `net8.0` and its `.csproj` documents that the image must have the Hosting Bundle installed for IIS to load ANCM. For a production golden image add a provisioner that installs the ASP.NET Core Hosting Bundle before Sysprep (or layer it via Octopus at deploy time).

*(Skip Step 1 entirely when `image_source = "jfrog"` and your VHD already exists in Artifactory — see §4.4.)*

---

## 4. Step 2 — Deploy network + compute + policy (Terraform, no Octopus needed)

With the default `enable_octopus_stage = false`, this plans and applies with **no Octopus connectivity**: RG, VNet/subnets/NSGs, the compliance policy assignments, and the VM(s) from the golden image — each with a system‑assigned managed identity, boot diagnostics, and a Tentacle‑registration CustomScript extension.

### 4.1 Prepare tfvars

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# then merge in the values you need from:
#   terraform.tfvars.compute.example   (image_source, compute_*, jfrog_*)
#   terraform.tfvars.octopus.example   (octopus_*, only needed for Step 3)
```

Keep secrets out of `terraform.tfvars` (§2). For the gallery path, confirm these match what Packer published:

```hcl
image_source                        = "gallery"
compute_compute_gallery_name        = "gal_msmf"
compute_image_definition_name       = "win2022-iis-octopus"
compute_image_version               = "latest"          # or a pinned "1.0.0"
compute_gallery_resource_group_name = "rg-msmf-gallery"
compute_vm_count                    = 2                  # default; vm-msmf-01, vm-msmf-02
compute_vm_size                     = "Standard_D2s_v5"
```

### 4.2 Init, plan, apply

```bash
terraform init          # add -backend-config=... to use remote state (stub in providers.tf — see §8)
terraform plan  -out=msmf.tfplan
terraform apply msmf.tfplan
```

The network layer alone is ~**15 resources** (RG + VNet + `app`/`mgmt` subnets + 2 NSGs with their rules). The policy stage adds **seven** RG‑scoped assignments (one require‑tag per key in `project`/`env`/`owner`, allowed‑locations, deny‑NIC‑public‑IP, subnet‑NSG audit, disk‑encryption audit). Compute adds the VMs, NICs, and the register extension.

### 4.3 `-target` ordering (optional but recommended for a clean demo)

A single `apply` resolves dependencies correctly (compute `depends_on` the RG and VNet). If you prefer to stage it — or to reproduce the self‑cleaning simulation — apply the **network layer first**, then the full apply for compute + policy:

```bash
# 1) network only (same targets scripts/simulate-run.sh uses):
terraform apply \
  -target=module.resource_group -target=module.vnet \
  -target=module.nsg_app -target=module.nsg_mgmt

# 2) then the rest (compute + policy):
terraform apply
```

> **Registration timing note:** the register extension always runs at boot and dials `octopus_server_url`. If you create compute *before* any Octopus server exists, the extension reports a failure that is harmless to the VM — re‑run it or re‑apply after Stage 3. For a clean end‑to‑end demo, do Step 3 **first** (or in the same apply), per §5.

### 4.4 JFrog image path (`image_source = "jfrog"`)

Set `image_source = "jfrog"` and provide the endpoint/staging values plus `TF_VAR_jfrog_access_token`. On apply, `terraform_data.jfrog_vhd_import` runs `scripts/import-jfrog-vhd.ps1` (PowerShell 7 + `az` + native `curl` on the runner): it stream‑downloads the VHD (Bearer token preferred; credentials passed to curl via a stdin config, never argv), uploads it as a **page blob** to the staging account, and `azurerm_image.jfrog` wraps it as a generalized managed image. Both paths converge on `local.compute_source_image_id`, so the VM module is identical.

### 4.5 Expected outputs

```bash
terraform output
```

- **Network:** `resource_group_name`, `resource_group_id`, `location`, `vnet_id`, `vnet_name`, `app_subnet_id`, `mgmt_subnet_id`, `nsg_app_id`, `nsg_mgmt_id`
- **Compute:** `compute_vm_names`, `compute_vm_resource_ids`, `compute_vm_private_ips`, `compute_vm_nic_ids`, `compute_vm_principal_ids` (system‑assigned MI principal IDs — grant these *Key Vault Secrets User* for the production secret‑pull pattern), `compute_source_image_resource_id`, `compute_image_source`
- **Policy:** `policy_assignment_ids` (control → assignment id), `policy_enforcement_mode`
- **Octopus:** `octopus_project_id`, `octopus_project_name`, `octopus_lifecycle_id`, `octopus_environment_ids`, `octopus_builtin_feed_id`, `octopus_target_roles`, `octopus_registered_target_ids` — all `null`/empty while the stage is gated off.

---

## 5. Step 3 — Enable Octopus + CI/CD (Dev → Test → Prod)

### 5.1 Turn on the Octopus stage

Merge the Stage‑3 values into `terraform.tfvars` (from `terraform.tfvars.octopus.example`), set the real `octopus_server_url` (and matching `octopus_space_id`), supply the API key via the environment, and flip the flag:

```bash
export TF_VAR_octopus_api_key='API-XXXX...'          # from Key Vault / CI secret store
terraform apply -var 'enable_octopus_stage=true'
```

This brings the whole of Stage 3 into the same state: the **Development / Test / Production** environments, the sequential lifecycle `MSMF Dev-Test-Prod`, project group `MS Migration Factory`, project `MSMF Golden Image App`, its project variables (`MSMF.IIS.*`, `Msmf:Environment` scoped per environment), and the "Deploy IIS Web App" process that targets the `iis-web-server` role.

**Guaranteed ordering (environments before Tentacles self‑register).** In a combined apply the fast Octopus resources virtually always finish before the VM extensions execute. For guaranteed ordering, create the Octopus resources first with a targeted apply, then run the full apply:

```bash
terraform apply -var 'enable_octopus_stage=true' \
  -target='octopusdeploy_deployment_process.this[0]' \
  -target='octopusdeploy_variable.environment_name_dev[0]' \
  -target='octopusdeploy_variable.environment_name_test[0]' \
  -target='octopusdeploy_variable.environment_name_prod[0]' \
  -target='octopusdeploy_variable.iis_website_name[0]' \
  -target='octopusdeploy_variable.iis_app_pool_name[0]' \
  -target='octopusdeploy_variable.iis_binding_port[0]'

terraform apply -var 'enable_octopus_stage=true'
```

> **Environment mapping is single‑source‑of‑truth.** Compute self‑registration derives its environment from the *same* variables Stage 3 uses: shared `environment` `dev` → `octopus_dev_environment_name` (`Development`), `test` → `Test`, `prod` → `Production`. Out of the box the registered environment always exists. Override with `compute_octopus_environment` only for a non‑standard mapping.
>
> **Keep the flag on** for every subsequent plan/apply of this state — turning it off plans destruction of the Octopus resources (which then needs a reachable server).

### 5.2 Run the pipeline (package the app, promote through the environments)

The sample app is `src/MSMF.GoldenImage.WebApp` (package id `MSMF.GoldenImage.WebApp`). Both pipelines do the same shape: `dotnet publish` → `octopus package nuget create` → `octopus package upload` (to the built‑in feed) → `octopus release create` → deploy **Development** → gated promotion to **Test** → **Production**, each deploy blocking on completion.

**Azure DevOps** — `pipelines/azure-pipelines.yml` (uses the shared `pipelines/steps-install-octopus-cli.yml` template, Octopus CLI `2.21.4`):

1. Import the YAML as a pipeline.
2. Set pipeline variables: `OctopusServerUrl` (plain), `OctopusSpace` (plain), and **`OctopusApiKey` (secret)** — or bind from a Key Vault‑backed variable group.
3. Create ADO Environments `MSMF-Development`, `MSMF-Test`, `MSMF-Production`, and add **Approvals and checks** to `MSMF-Test` and `MSMF-Production` to gate promotion.

**GitHub Actions** — `pipelines/github-actions-deploy.yml` (first‑party OctopusDeploy actions):

1. Repository **variables**: `OCTOPUS_SERVER_URL`, `OCTOPUS_SPACE`.
2. Repository **secret**: `OCTOPUS_API_KEY`.
3. Create GitHub Environments `Development`, `Test`, `Production`, and add **Required reviewers** to `Test` and `Production`.

> The deployment process targets the `iis-web-server` **role**, so the pipeline never names machines — new golden‑image VMs are picked up automatically once they self‑register. Human sign‑off lives in the pipeline platform (ADO checks / GitHub reviewers); the Octopus lifecycle enforces *sequence* (Dev → Test → Prod, no phase skippable) but not sign‑off. To gate inside Octopus too, add an `Octopus.Manual` step (sketch in `octopus.tf`).

---

## 6. Verification — confirm each stage worked

**Stage 1 (image):**
```bash
az sig image-version show \
  --resource-group rg-msmf-gallery --gallery-name gal_msmf \
  --gallery-image-definition win2022-iis-octopus --gallery-image-version 1.0.0 \
  --query "{state:provisioningState, regions:publishingProfile.targetRegions[].name}"
```
Expect `provisioningState = Succeeded` and your replication regions. `packer-build-manifest.json` records the same coordinates.

**Stage 2 (network/compute/policy):**
```bash
terraform output compute_vm_names
terraform output compute_vm_private_ips
az resource list -g "$(terraform output -raw resource_group_name)" \
  --query "[].{name:name,type:type}" -o table
az policy assignment list \
  --scope "$(terraform output -raw resource_group_id)" \
  --query "[].{name:name, enforcement:enforcementMode}" -o table
```
Expect the VNet, two NSGs, the VMs/NICs, and seven policy assignments in `Default` (enforced) mode. **Compliance demo:** with enforcement on, try to add an untagged resource or a public IP to the RG — the deny is the feature.

**Stage 3 (Octopus):**
```bash
terraform output octopus_environment_ids   # Development / Test / Production
terraform output octopus_project_name      # "MSMF Golden Image App"
terraform output octopus_builtin_feed_id
```
In the Octopus UI, confirm the environments/lifecycle/project exist and that the VMs appear under **Infrastructure → Deployment Targets** with the `iis-web-server` role (they self‑register at first boot; check `C:\ProgramData\msmf-bootstrap\register-octopus-tentacle.log` on a VM if a target is missing).

**Application:** after the release lands, browse the VM's private IP via Bastion/jump host. The golden image serves `/` and `/health.html` (`OK`) out of the box; once Octopus deploys the app, `/` renders the "Golden Image IIS Web App" page and `/healthz` is the liveness probe. Public IPs are policy‑denied and port 80 is off by default (`app_enable_http = false`), so reach the app over the app subnet.

**End‑to‑end smoke test without cost:** `scripts/simulate-run.sh` (or `scripts/simulate-run.ps1`) runs `init` + `validate` + a full‑stack `plan`, applies **only** the network layer into a throwaway RG, prints live resources as evidence, and tears everything down on exit — see §7.

---

## 7. Teardown

One root module — one destroy. If Stage 3 was enabled, keep the flag on so the Octopus resources (which need a reachable server to delete) are included:

```bash
cd terraform
terraform destroy -var 'enable_octopus_stage=true'   # or plain `terraform destroy` if Stage 3 was never enabled
```

Golden‑image artifacts (only if you want them gone):

```bash
az sig image-version delete \
  --resource-group rg-msmf-gallery --gallery-name gal_msmf \
  --gallery-image-definition win2022-iis-octopus --gallery-image-version 1.0.0
# or drop the whole images RG:
az group delete -n rg-msmf-gallery --yes
```

**Self‑cleaning mockup test** (proves the stack against real Azure, then deletes everything — even on error):

```bash
./scripts/simulate-run.sh              # plan (full stack) + apply network + teardown
./scripts/simulate-run.sh --plan-only  # authenticate + plan only, zero resources created
# PowerShell equivalent:
#   ./scripts/simulate-run.ps1 [-PlanOnly]
```

It creates a throwaway `rg-msmf-sim-<rand>` (tagged `ttl=temporary`), applies only `module.resource_group` / `module.vnet` / `module.nsg_app` / `module.nsg_mgmt`, prints evidence, then `terraform destroy` + `az group delete` in a `trap`/`finally` so nothing is left behind.

**Also clean up:** self‑registered Tentacles may linger as *offline* targets in Octopus after the VMs are gone — delete them from **Infrastructure → Deployment Targets** (or manage them explicitly via `octopus_deployment_targets` so Terraform owns their lifecycle). Purge the JFrog staging container if `image_source = "jfrog"` was used, and **rotate the Octopus API key** (§8).

---

## 8. State hygiene & production hardening

**Terraform state for this root contains secrets — treat the state file as secret material.**

- The Octopus API key is embedded in the VM extension's `protected_settings`. Azure encrypts `protected_settings` at rest and never returns it via portal/CLI/ARM — but the value is **persisted verbatim in `terraform.tfstate`**.
- When `compute_admin_password` is left `null`, the AVM module **generates** a local‑admin password, which is also written to state.
- `sensitive = true` redacts CLI/plan *output* only; it does **not** encrypt state. These values can't be `ephemeral` because they must persist into provider/extension attributes.

**Non‑negotiables for anything beyond a throwaway demo:**

1. **Remote, encrypted, access‑controlled state.** Uncomment the `backend "azurerm"` stub in `terraform/providers.tf` (`use_azuread_auth = true`), point it at an RBAC‑restricted container on an encrypted storage account, and `terraform init -reconfigure`. Never run with local state; securely delete any local `terraform.tfstate` from experiments.
2. **Rotate the Octopus API key after provisioning.** Use a dedicated service account whose key is scoped to machine registration in the one Space, and rotate it once the fleet is registered (registration is a one‑shot, first‑boot action).
3. **Keep the key out of Terraform entirely (production pattern).** Have each VM pull the key from **Azure Key Vault using its system‑assigned managed identity** at boot (grant the `compute_vm_principal_ids` *Key Vault Secrets User*) instead of receiving it via the extension. The IMDS + Key Vault REST sketch is in the comments of `terraform/compute.tf`; it removes the secret from state *and* from the extension, and makes rotation a vault‑only operation.
4. **Rotate anything that ever passed through a local/demo state file** (admin password included).

**Additional hardening for a real rollout:**

- **Pin providers + modules.** Commit `.terraform.lock.hcl` after the first `init`. Pin the Octopus provider exactly (`~> 0.43`). The AVM modules are already pinned (`resourcegroup >= 0.1.0, < 1.0.0`; `nsg >= 0.2.0, < 1.0.0`; `vnet >= 0.4.0, < 1.0.0`; `compute-virtualmachine 0.21.0`).
- **Supply‑chain pin the Tentacle MSI** — set `tentacle_msi_sha256` + a pinned `tentacle_download_url` so a tampered download fails the build.
- **Keep policy enforcement on** — `policy_enforcement_mode = "Default"`. Relax to `"DoNotEnforce"` only for an audit‑only dry run, then flip it back. A compliance baseline that ships disabled demonstrates nothing.
- **Network egress** — the VNet keeps platform default outbound access so first‑boot VMs can reach Octopus/feeds/Azure. Azure is retiring implicit outbound; for production add an explicit NAT Gateway (`avm-res-network-natgateway`) and set `default_outbound_access_enabled = false` on each subnet (see the note in `network.tf`).
- **Keep VMs private** — `compute_enable_public_ip = false` and `policy_deny_public_ip = true` reinforce each other. Reach VMs through Azure Bastion or the mgmt‑subnet jump host. RDP from the Internet is rejected by variable validation on `mgmt_rdp_source_cidrs`. HTTP (80) stays off unless you set `app_enable_http = true`.
- **Add the ASP.NET Core Hosting Bundle** to the golden image (§3.3) so ANCM can host the `net8.0` app under IIS.
