# MS Migration Factory — Golden Image Prep (Terraform + Packer + Octopus PoC)

> **Project tag:** `project = msmf-golden-image` · **Region default:** East US · **Audience:** Microsoft-facing proof of concept.
>
> A runnable, idempotent, three-stage proof of concept that bakes a **golden Windows Server image** (IIS + Octopus Tentacle), stands up **Azure infrastructure from that image** with Terraform + Azure Verified Modules, and **maps the deployed VMs into Octopus Deploy** with a Dev → Test → Prod CI/CD pipeline. Everything is parameterized; no secrets in code.

---

## 1. What this PoC is

The Migration Factory pattern is: **standardize the workload into a golden image once, then reproduce it on demand as compliant Azure infrastructure, wired straight into a promotion-based deployment pipeline.** This PoC implements that end-to-end for a classic IIS web workload:

| Stage | Tool | Output |
|-------|------|--------|
| **1. Golden image** | **Packer** (`azure-arm`) | A generalized Windows Server 2022 image (IIS + Octopus Tentacle baked in), published as an **Azure Compute Gallery** image version: `rg-msmf-gallery / gal_msmf / win2022-iis-octopus`. |
| **2. Azure infra** | **Terraform** + **Azure Verified Modules** (single root: `terraform/`) | Resource group, VNet/subnets/NSGs, and VM(s) created **from the golden image**, with managed identity, boot diagnostics, and a self-registration custom script. Compliance enforced by **Azure Policy** (`policy.tf`). |
| **3. Octopus + CI/CD** | **`octopusdeploy` Terraform provider** + a pipeline | Environments (Development/Test/Production), lifecycle, project, deployment process — **gated behind `enable_octopus_stage`** — driven by an Azure Pipelines / GitHub Actions release. |

**Three owner-specific capabilities are first-class in this PoC:**

- **Dual golden-image source** — the compute stage pulls the image from **EITHER** an Azure Compute Gallery version **OR** a **JFrog Artifactory** VHD artifact, controlled by a single toggle `image_source = "gallery" | "jfrog"`.
- **the compliance baseline security-compliance baseline via Azure Policy** — `terraform/policy.tf` assigns built-in policies (required tags, allowed locations, deny-public-IP, NSG-on-subnet, disk-encryption audit) at the resource-group scope, **enforced by default** (see §8).
- **Stage gating** — `enable_octopus_stage` (default `false`) keeps every `octopusdeploy` resource *and data source* out of the plan, so **network + compute plan/apply cleanly with no reachable Octopus server** (see §6a).

---

## 2. Architecture overview

```
              STAGE 1 — GOLDEN IMAGE  (Packer, azure-arm builder)
  ┌────────────────────────────────────────────────────────────────────┐
  │  Windows Server 2022 base image (Azure Marketplace)                 │
  │    + install-iis.ps1            -> Install-WindowsFeature Web-Server │
  │                                    (+ Web-Mgmt-Tools, ASP.NET 4.8,   │
  │                                     Web-Asp-Net45, Web-Http-Logging) │
  │    + install-octopus-tentacle.ps1 -> Tentacle MSI (SHA256-verified)  │
  │                                      installed, registration STAGED  │
  │    + sysprep / generalize                                           │
  │                    │  capture                                        │
  │                    ▼                                                 │
  │        Azure Compute Gallery  ──►  image version                    │
  │        rg-msmf-gallery / gal_msmf / win2022-iis-octopus : 1.0.x     │
  └────────────────────┬───────────────────────────────────────────────┘
                       │
     image_source="gallery"           image_source="jfrog"
                       │                        │
                       │            VHD in JFrog Artifactory
                       │            (scripts/import-jfrog-vhd.ps1:
                       │             download → stage as page blob →
                       │             azurerm_image → managed image)
                       ▼                        ▼
              STAGE 2 — AZURE INFRA  (terraform/ — one root module)
  ┌────────────────────────────────────────────────────────────────────┐
  │  Resource Group            (AVM avm-res-resources-resourcegroup)    │
  │  VNet + subnets + NSGs     (AVM avm-res-network-virtualnetwork /    │
  │                             avm-res-network-networksecuritygroup)   │
  │  N VMs FROM the image      (AVM avm-res-compute-virtualmachine)     │
  │     • system-assigned managed identity                             │
  │     • boot diagnostics (managed storage)                           │
  │     • CustomScriptExtension → Tentacle self-registers with Octopus  │
  │  Azure Policy baseline     (policy.tf — the compliance baseline, ENFORCED)       │
  └────────────────────┬───────────────────────────────────────────────┘
                       │  targets registered (roles: msmf-web,iis-web-server)
                       ▼
              STAGE 3 — OCTOPUS DEPLOY  (octopus.tf, enable_octopus_stage=true)
  ┌────────────────────────────────────────────────────────────────────┐
  │  Environments:   Development ──►  Test  ──►  Production             │
  │  Lifecycle  +  Project Group  +  Project  +  Deployment Process     │
  │  Deployment targets:  the Stage-2 VMs (self-registered Tentacles)   │
  └────────────────────┬───────────────────────────────────────────────┘
                       │
                       ▼
              STAGE 4 — CI/CD  (pipelines/azure-pipelines.yml |
                                pipelines/github-actions-deploy.yml)
        dotnet publish  →  pack .nupkg  →  push to built-in feed
              →  create release  →  deploy Development  →  Test  →  Production
```

---

## 3. Repository layout

```
msmf-golden-image-poc/
├── README.md                          ← this runbook
├── terraform.tfvars.example           ← POINTER ONLY → the real examples live in terraform/
│
├── packer/                            ← STAGE 1
│   ├── windows-golden-image.pkr.hcl   ← azure-arm source + build (captures to gallery)
│   ├── variables.pkr.hcl              ← all inputs (secrets marked sensitive)
│   ├── windows-golden-image.pkrvars.hcl.example
│   └── README.md                      ← stage-1 detail runbook
│
├── terraform/                         ← STAGES 2 + 3 (ONE root module, ONE state)
│   ├── providers.tf                   ← terraform >= 1.10, azurerm ~> 4.0, octopusdeploy, backend stub, common_tags
│   ├── variables.tf                   ← SHARED + NETWORK + POLICY inputs (incl. enable_octopus_stage)
│   ├── network.tf                     ← RG + VNet/subnets + NSGs (AVM)
│   ├── compute.tf                     ← VMs from the golden image (AVM) + gallery|jfrog toggle + register extension
│   ├── variables.compute.tf           ← compute_* / jfrog_* / image_source inputs
│   ├── outputs.compute.tf             ← VM names/ids/IPs/principal ids
│   ├── policy.tf                      ← Azure Policy compliance baseline (+ its outputs)
│   ├── octopus.tf                     ← environments, lifecycle, project, process (ALL gated)
│   ├── variables.octopus.tf           ← octopus_* inputs
│   ├── outputs.octopus.tf             ← project/feed/environment ids (null/empty while gated off)
│   ├── terraform.tfvars.example           ← shared + network + policy values
│   ├── terraform.tfvars.compute.example   ← compute values
│   └── terraform.tfvars.octopus.example   ← octopus values
│
├── src/
│   └── MSMF.GoldenImage.WebApp/       ← ASP.NET Core 8 app deployed by Octopus (+ appsettings.json)
│
├── pipelines/
│   ├── azure-pipelines.yml            ← Azure DevOps: build → pack → push → release → promote
│   ├── github-actions-deploy.yml      ← GitHub Actions equivalent
│   └── steps-install-octopus-cli.yml  ← shared ADO step template
│
└── scripts/
    ├── 00-prereq-gallery.ps1          ← creates gallery + image definition (idempotent)
    ├── install-iis.ps1                ← Packer provisioner: IIS + health page
    ├── install-octopus-tentacle.ps1   ← Packer provisioner: Tentacle MSI (SHA256 check) + staging
    ├── register-octopus-tentacle.ps1  ← first-boot self-registration (CustomScript extension)
    └── import-jfrog-vhd.ps1           ← JFrog VHD → staging page blob (creds via stdin, never argv)
```

> **One Terraform root, one state.** Network, compute, policy and Octopus all live in `terraform/` and share `providers.tf`, `local.common_tags` and one `terraform.tfvars`. The Octopus stage is isolated **logically** (not by state root) via `enable_octopus_stage` — see §6a. Variables are namespaced per stage (`compute_*`, `jfrog_*`, `octopus_*`, `policy_*`) plus shared plumbing (`project_name`, `environment`, `location`, `owner`, …).

---

## 4. Prerequisites

| Requirement | Version / detail |
|-------------|------------------|
| **Azure subscription** | Contributor **+** *Resource Policy Contributor* (for `policy.tf`) **+** *Managed Identity Operator*. |
| **Azure CLI** | `az` ≥ 2.60, logged in: `az login` then `az account set --subscription <id>`. |
| **Packer** | ≥ 1.9 (`packer version`). Plugin `github.com/hashicorp/azure ~> 2.1` auto-installed via `packer init`. |
| **Terraform** | **≥ 1.10** (`required_version` in `providers.tf`; the pinned AVM compute module v0.21.0 itself requires 1.10). |
| **azurerm provider** | `~> 4.0` (pinned in `providers.tf`). |
| **octopusdeploy provider** | `OctopusDeployLabs/octopusdeploy >= 0.21, < 2.0` (shared pin in `providers.tf`; Stage 3 verified against 0.43.x — pin exactly + commit `.terraform.lock.hcl` for reproducible builds). |
| **Octopus Server** | *Only needed when `enable_octopus_stage = true`.* Cloud (`https://<you>.octopus.app`) or self-hosted, reachable from Azure. An **API key** (`API-…`) with rights to manage the target Space. |
| **JFrog Artifactory** *(only if `image_source="jfrog"`)* | Base URL, repo path to a generalized Windows VHD, and a read token. |
| **Shell** | All scripts are PowerShell (`scripts/*.ps1`); `import-jfrog-vhd.ps1` needs PowerShell 7 (`pwsh`) + `az` + native `curl` on the Terraform runner. |

**Auth for Packer & Terraform** uses the Azure CLI session by default (`az login` / `use_azure_cli_auth`). For unattended CI, set a service principal via env vars: `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` (Terraform) and the matching `client_id`/`client_secret`/`tenant_id`/`subscription_id` Packer vars.

---

## 5. Azure Verified Modules (AVM) used

The infra stage composes official AVM modules from the Terraform Registry rather than hand-rolling every `azurerm` resource. These are the **actual pins in the code**:

| Purpose | AVM module | Pin (as coded) |
|---------|-----------|----------------|
| Resource group | `Azure/avm-res-resources-resourcegroup/azurerm` | `>= 0.1.0, < 1.0.0` |
| Network security groups | `Azure/avm-res-network-networksecuritygroup/azurerm` | `>= 0.2.0, < 1.0.0` |
| VNet + subnets (+ NSG association) | `Azure/avm-res-network-virtualnetwork/azurerm` | `>= 0.4.0, < 1.0.0` |
| VM(s) from the golden image | `Azure/avm-res-compute-virtualmachine/azurerm` | `0.21.0` (exact) |

> After the first `terraform init`, commit `.terraform.lock.hcl` so every run resolves identical module/provider builds.

**Deliberate raw-`azurerm` fallbacks (no suitable AVM module):**

- **JFrog VHD import** — `azurerm_image` created from the staged blob (driven by `scripts/import-jfrog-vhd.ps1` via `terraform_data` + `local-exec`). There is no AVM module for "import a VHD as a managed image."
- **Azure Policy baseline** — `azurerm_resource_group_policy_assignment` per control against **built-in** policy definitions (`data "azurerm_policy_definition"` by display name). The full ALZ policy experience lives in the heavier `Azure/avm-ptn-alz` pattern module; for a resource-group-scoped PoC baseline, per-control assignments are clearer and cheaper to reason about.
- **Octopus resources** — the `octopusdeploy` provider is not part of AVM (AVM is Azure-only).

---

## 6. Run order (step by step)

> Copy the example tfvars first: `cd terraform && cp terraform.tfvars.example terraform.tfvars`, then merge in what you need from `terraform.tfvars.compute.example` / `terraform.tfvars.octopus.example`. Keep secrets **out** of it — see §9.

### Step 0 — one-time: gallery + image definition

```powershell
./scripts/00-prereq-gallery.ps1 `
    -ResourceGroup rg-msmf-gallery `
    -GalleryName   gal_msmf `
    -Location      eastus `
    -ImageDefinition win2022-iis-octopus
```

These names are the **cross-stage contract**: they are the shared defaults of `packer/variables.pkr.hcl` (`gallery_resource_group`/`gallery_name`/`image_definition_name`) *and* `terraform/variables.compute.tf` (`compute_gallery_resource_group_name`/`compute_compute_gallery_name`/`compute_image_definition_name`). Change them together or not at all.

### Step 1 — Packer: build the golden image

```bash
cd packer
cp windows-golden-image.pkrvars.hcl.example windows-golden-image.pkrvars.hcl   # edit

packer init .
packer validate -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl
packer build    -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl
# → generalizes the VM and publishes:
#   gal_msmf / win2022-iis-octopus : <image_version>   (in rg-msmf-gallery)
```

What the build does: provisions IIS (`install-iis.ps1`), downloads + **SHA256-verifies** + installs the Octopus Tentacle MSI and stages the registration script (`install-octopus-tentacle.ps1` — registration itself is deferred to first boot), then sysprep-generalizes and captures the image version into the gallery.

> **Supply-chain pin (recommended):** set `tentacle_download_url` to a specific version URL and `tentacle_msi_sha256` to its checksum — the build then **fails hard** on any hash mismatch. Leaving the hash empty installs with a loud warning only.

*(Skip this step when `image_source="jfrog"` and your VHD already exists in Artifactory.)*

### Step 2 — Terraform: network + compute + policy (no Octopus needed)

```bash
cd ../terraform
terraform init          # add -backend-config=... to use remote state (stub in providers.tf) — see §9a
terraform plan  -out=msmf.tfplan
terraform apply msmf.tfplan
```

With the default `enable_octopus_stage = false`, this plans and applies **without any Octopus connectivity**: RG, VNet/subnets/NSGs, the compliance policy assignments, and the VM(s) **from the golden image** (gallery version *or* the JFrog-imported managed image, per `image_source`), each with a system-assigned managed identity, boot diagnostics, and the Tentacle-registration CustomScript extension.

> **Note:** the registration extension always runs at boot and dials `octopus_server_url`. If you apply compute before any Octopus server exists, the extension reports a (harmless to the VM) failure; re-run it or re-apply after Stage 3. For a clean end-to-end demo, do Step 3 **first** or in the same apply (below).

### Step 3 — Terraform: Octopus (environments, project, process)

```bash
export TF_VAR_octopus_api_key='API-XXXX...'   # from Key Vault / CI secret store
terraform apply -var 'enable_octopus_stage=true'   # plus real octopus_server_url in tfvars
```

Flipping `enable_octopus_stage = true` brings the whole Stage 3 into the same state: **Development / Test / Production** environments, the sequential lifecycle, project group + project, and the deployment process that deploys the IIS app to the `iis-web-server` role.

- **Ordering with compute:** environments must exist before a Tentacle can self-register. In a combined apply the (fast) Octopus resources virtually always finish before the VM extensions execute; for guaranteed ordering, apply Stage 3 first on its own:
  `terraform apply -var 'enable_octopus_stage=true' -target='octopusdeploy_deployment_process.this[0]' -target='octopusdeploy_variable.environment_name_dev[0]' -target='octopusdeploy_variable.environment_name_test[0]' -target='octopusdeploy_variable.environment_name_prod[0]' -target='octopusdeploy_variable.iis_website_name[0]' -target='octopusdeploy_variable.iis_app_pool_name[0]' -target='octopusdeploy_variable.iis_binding_port[0]'` — then run the full apply.
- **Environment mapping (single source of truth):** compute self-registration derives its environment from the *same* variables Stage 3 uses to create environments: shared `environment` `dev`→`octopus_dev_environment_name` (`Development`), `test`→`Test`, `prod`→`Production`. Out of the box the registered environment therefore always exists. Override with `compute_octopus_environment` only for non-standard mappings.
- **Keep the flag on** for subsequent plans/applies of the same state, otherwise Terraform will plan to destroy the Octopus resources.

### Step 4 — CI/CD: package the app and deploy it through the environments

- **Azure DevOps:** import `pipelines/azure-pipelines.yml`; set pipeline variables `OctopusServerUrl`, `OctopusSpace` and secret `OctopusApiKey`, and create ADO Environments `MSMF-Development/-Test/-Production` with approvals on Test/Production. The pipeline: `dotnet publish` → pack `.nupkg` (`MSMF.GoldenImage.WebApp`) → push to the Octopus built-in feed → create release → deploy Development → gated promotion to **Test** and **Production**.
- **GitHub Actions:** use `pipelines/github-actions-deploy.yml` with repo variables `OCTOPUS_SERVER_URL`, `OCTOPUS_SPACE`, secret `OCTOPUS_API_KEY`, and GitHub Environments `Development/Test/Production` (required reviewers on Test/Prod).

After the release lands, browse to the VM's private IP over **HTTPS** (via Bastion/jumpbox — public IPs are policy-denied and port 80 is off by default, §8/§10) and confirm the IIS site serves the deployed app.

---

## 6a. The `enable_octopus_stage` gate (why plans work without Octopus)

Everything Octopus-side — including the `data "octopusdeploy_feeds"` / `data "octopusdeploy_machine_policies"` **data sources**, which would otherwise be read at *plan* time — carries `count = var.enable_octopus_stage ? 1 : 0` (or an equivalently gated `for_each`). Consequences:

- `terraform plan`/`apply`/`destroy` with the flag **off** never contacts an Octopus server; the placeholder `octopus_server_url` and empty `octopus_api_key` defaults are fine.
- All cross-references are count-indexed (`octopusdeploy_project.this[0]`), and the `octopus_*` **outputs** are wrapped in `one()`/`try()` — they return `null`/`{}` while the stage is off instead of erroring.
- The flag is a *lifecycle* switch, not a feature flag: turning it off on a state that has Octopus resources plans their destruction (which then *does* need connectivity).

---

## 7. Golden-image source toggle (`gallery` vs `jfrog`)

The compute stage (`terraform/compute.tf`) reads exactly one source, selected by `image_source`:

**`image_source = "gallery"`** *(default, recommended)* — resolves the image via `data "azurerm_shared_image_version" "golden"` using `compute_compute_gallery_name` (`gal_msmf`), `compute_image_definition_name` (`win2022-iis-octopus`), `compute_gallery_resource_group_name` (`rg-msmf-gallery`) and `compute_image_version` (`"latest"` or a pinned `1.0.x`) — i.e. **exactly what Packer publishes with its defaults**.

**`image_source = "jfrog"`** — the VHD is pulled from Artifactory and imported as a managed image before compute:

1. `terraform_data.jfrog_vhd_import` (local-exec, PowerShell 7) runs `scripts/import-jfrog-vhd.ps1`: stream-download from `jfrog_base_url`/`jfrog_repo_path` (Bearer token preferred; creds passed to curl **via stdin config, never argv**) and upload as a **page blob** into the staging storage account.
2. `azurerm_image.jfrog` wraps that blob as a generalized Windows managed image.

Both paths converge on `local.compute_source_image_id`, so the VM module is identical regardless of source. JFrog credentials are **sensitive variables** (`jfrog_access_token` / `jfrog_username`+`jfrog_password`) passed to the script as environment variables — never committed, never in argv (see §9).

---

## 8. Security & compliance — the compliance baseline (Azure Policy)

`terraform/policy.tf` assigns **built-in** policy definitions (resolved by display name via `data "azurerm_policy_definition"`) at the workload resource-group scope, one `azurerm_resource_group_policy_assignment` per control:

| Control | Effect | Backing built-in policy | Knob |
|---------|--------|-------------------------|------|
| **Require tags** `project`, `env`, `owner` | Deny | *Require a tag on resources* (one assignment per key) | `policy_required_tag_keys` |
| **Allowed locations** | Deny | *Allowed locations* | `policy_allowed_locations` |
| **Deny public IPs on NICs** | Deny | *Network interfaces should not have public IPs* | `policy_deny_public_ip` (default `true`; set `false` only if `compute_enable_public_ip = true` is genuinely needed) |
| **NSG on every subnet** | AuditIfNotExists | *Subnets should be associated with a Network Security Group* (built-in has no deny variant; `network.tf` already associates NSGs, so this control **proves** compliance) | — |
| **Disk-encryption audit** | AuditIfNotExists | *Windows virtual machines should enable Azure Disk Encryption or EncryptionAtHost* | `policy_require_disk_encryption` |

**Enforcement is ON by default:** `policy_enforcement_mode = "Default"` (deny effects actually block non-compliant creates). Relax to `"DoNotEnforce"` *only* for an audit-only dry run — and flip it back. This is deliberate: a compliance baseline that ships disabled demonstrates nothing.

> Demo tip: with enforcement on, try adding an untagged resource or a public IP to the RG — the deny is the feature.

---

## 9. Variable & secret checklist — *where each value lives*

**Golden rule:** non-secret configuration → `terraform/terraform.tfvars`; secrets → **Key Vault** (surfaced as `TF_VAR_*` at apply time) or a CI secret store; application runtime secrets → **Octopus sensitive variables** (never in Terraform or Git).

| Value(s) | Lives in | Secret? | Notes |
|----------|----------|:-------:|-------|
| `subscription_id`, `tenant_id` | tfvars or `ARM_*` env / `az login` session | ▫ | azurerm 4.x needs a subscription; null falls back to env/CLI. |
| `location`, `project_name`, `environment`, `owner`, `tags` | tfvars | ▫ | Feed the `{project, env, owner}` tag baseline (`local.common_tags`). |
| `image_source`, `compute_compute_gallery_name`, `compute_image_definition_name`, `compute_image_version`, `compute_gallery_resource_group_name` | tfvars | ▫ | Gallery coordinates — keep identical to the Packer side. |
| `jfrog_base_url`, `jfrog_repo_path`, `jfrog_staging_*`, `jfrog_vhd_blob_name` | tfvars | ▫ (low) | Endpoint + staging coordinates. |
| **`jfrog_access_token`** (or `jfrog_username`/`jfrog_password`) | **Key Vault → `TF_VAR_jfrog_access_token`** | 🔒 | Sensitive vars; handed to the import script as env vars, then to curl via stdin. |
| `vnet_address_space`, `app_subnet_address_prefixes`, `mgmt_subnet_address_prefixes`, `mgmt_rdp_source_cidrs`, `app_http_source_prefix`, `app_enable_http`, `octopus_server_source_cidrs` | tfvars | ▫ | RDP-from-Internet is rejected by validation; HTTP 80 is opt-in. |
| `compute_vm_count`, `compute_vm_size`, `compute_vm_name_prefix`, `compute_availability_zones`, `compute_admin_username`, `compute_enable_public_ip` | tfvars | ▫ | |
| **`compute_admin_password`** | **Key Vault → `TF_VAR_compute_admin_password`** (or leave `null` to auto-generate) | 🔒 | Either way it lands in state — see §9a. |
| `enable_octopus_stage`, `octopus_server_url`, `octopus_space_id`, `octopus_*_environment_name`, `octopus_project_name`, `octopus_lifecycle_name`, `octopus_target_roles`, `octopus_iis_*`, `compute_octopus_*` | tfvars | ▫ | |
| **`octopus_api_key`** | **Key Vault / CI secret → `TF_VAR_octopus_api_key`** | 🔒 | Never in tfvars. Reaches state via protected_settings — see §9a. |
| `policy_*` | tfvars | ▫ | Compliance baseline knobs (§8). |
| **App connection strings / API keys / cert passwords** | **Octopus sensitive variables** (scoped per environment) | 🔒 | Runtime app secrets — never in TF/Git. |
| **Packer:** `client_secret`, `octopus_api_key`, `tentacle_msi_sha256` | env `PKR_VAR_client_secret` / `PKR_VAR_octopus_api_key`; hash is non-secret | 🔒/▫ | `*.pkrvars.hcl` is git-ignored. |

**Pull a KV secret into a `TF_VAR` at apply time (example):**

```bash
export TF_VAR_octopus_api_key=$(az keyvault secret show \
  --vault-name kv-msmf-secrets --name octopus-api-key --query value -o tsv)
export TF_VAR_compute_admin_password=$(az keyvault secret show \
  --vault-name kv-msmf-secrets --name vm-admin-password --query value -o tsv)
```

> Add `terraform.tfvars`, `*.pkrvars.hcl`, `*.tfplan`, `.terraform/`, and `*.tfstate*` to `.gitignore`. Consider a pre-commit secret scanner (e.g. gitleaks).

### 9a. State hygiene — READ THIS BEFORE ANY REAL RUN

Terraform state for this root **contains secrets** and must be treated as secret material:

- The Octopus API key is embedded in the VM extension's `protected_settings`. Azure encrypts protected_settings at rest and never returns it via portal/CLI/ARM — but the value **is persisted verbatim in `terraform.tfstate`**.
- When `compute_admin_password` is left `null`, the AVM module **generates** a local-admin password — which is also written to state.
- `sensitive = true` on these variables redacts CLI/plan *output* only; it does **not** encrypt state. Terraform's `ephemeral` variables can't be used here because these values must persist into provider/extension attributes.

Non-negotiables for anything beyond a throwaway demo:

1. **Remote, encrypted, access-controlled state.** Uncomment the `backend "azurerm"` stub in `providers.tf` (`use_azuread_auth = true`), store state in an RBAC-restricted container on an encrypted storage account, and never run with local state. Local `terraform.tfstate` from experiments must be securely deleted.
2. **Rotate the Octopus API key after provisioning.** Use a dedicated service account whose key is scoped to machine registration in the one Space, and rotate it once the fleet is registered (registration is a one-shot, first-boot action).
3. **Production alternative — keep the key out of Terraform entirely:** have the VM pull the key from **Azure Key Vault with its system-assigned managed identity** at boot (grant the principal ids exported by `outputs.compute.tf` *Key Vault Secrets User*) instead of receiving it via the extension. The exact IMDS + Key Vault REST sketch is in the comments of `terraform/compute.tf`; it removes the secret from state *and* from the extension, and makes rotation a vault-only operation.
4. Same policy for anything that ever passed through a local/demo state file: rotate it.

---

## 10. CI/CD pipeline wiring (summary)

Both pipelines do the same shape; pick the one matching your SCM:

```
build:   dotnet restore → dotnet publish -c Release → pack MSMF.GoldenImage.WebApp.<ver>.nupkg
push:    push package to the Octopus BUILT-IN feed        (server/space/API key from secrets)
release: create release <ver> for project "MSMF Golden Image App"
deploy:  deploy to Development (waits for completion)
promote: approval gate → Test → approval gate → Production
```

- `OctopusServerUrl`/`OCTOPUS_SERVER_URL`, `OctopusApiKey`/`OCTOPUS_API_KEY` (secret), `OctopusSpace`/`OCTOPUS_SPACE` are **pipeline variables/secrets** — not in YAML.
- **Human approval gates live in the pipeline platform** (ADO Environment checks / GitHub required reviewers). The Octopus lifecycle itself enforces *sequence* — a release must be deployed to Development, then Test, before Production is reachable (no phase is skippable) — but not sign-off; to gate inside Octopus as well, add a manual-intervention step to the deployment process (sketch in `octopus.tf`).
- The deployment process targets the `iis-web-server` **role**, so the pipeline never names machines — new VMs from the golden image are picked up automatically once they self-register.

---

## 11. Teardown

One root module — one destroy. If Stage 3 was enabled, keep the flag on so the Octopus resources (which need a reachable server to delete) are included:

```bash
cd terraform
terraform destroy -var 'enable_octopus_stage=true'   # or plain `terraform destroy` if Stage 3 was never enabled

# Golden image artifacts (only if you want them gone):
az sig image-version delete \
  --resource-group rg-msmf-gallery --gallery-name gal_msmf \
  --gallery-image-definition win2022-iis-octopus --gallery-image-version <ver>
# or drop the whole images RG:  az group delete -n rg-msmf-gallery --yes
```

> **Self-registered Tentacles:** machines that registered themselves at boot may linger as *offline* targets in Octopus after the VMs are gone — delete them from **Infrastructure → Deployment Targets** (or register them explicitly via `octopus_deployment_targets` so Terraform owns their lifecycle). Also purge the JFrog staging container if `image_source="jfrog"` was used. Rotate the Octopus API key (§9a).

---

## 12. What this proves for the Migration Factory

- **Golden image = the unit of standardization.** IIS, the Octopus Tentacle (checksum-verified supply chain), hardening, and agents are baked **once** into an immutable, versioned artifact. Every downstream VM is byte-identical and audited — no drifting hand-built servers.
- **Infrastructure is reproducible and compliant by construction.** One `terraform apply` recreates the full environment from the image, and the Azure Policy compliance baseline is applied — **enforced, not advisory** — in the same motion.
- **The image source is pluggable.** The `gallery | jfrog` toggle shows the same factory can consume images from an Azure-native gallery **or** an existing enterprise artifact estate (JFrog), with zero change to the compute code.
- **Deploy targets map themselves into a promotion pipeline.** VMs self-register into Octopus (into an environment name guaranteed to exist, because compute and Octopus share one set of environment-name variables) and inherit the Dev → Test → Prod lifecycle.
- **AVM + pinned providers = supportable, upgradeable IaC.** Microsoft-maintained building blocks, exact pins, and a lock file — the durability a factory needs to scale from one workload to hundreds.

---

## 13. Notes & gotchas

- **`terraform plan` needs no Octopus.** That is the whole point of `enable_octopus_stage` (§6a). If you see an Octopus auth/DNS error at plan time, the flag is on without real connection values.
- **Gallery names are a contract.** `rg-msmf-gallery` / `gal_msmf` / `win2022-iis-octopus` are the shared defaults of Packer *and* Terraform; if you rename them, rename them on **both** sides (`packer/variables.pkr.hcl` ↔ `terraform/variables.compute.tf`) or the `azurerm_shared_image_version` lookup finds nothing.
- **Port 80 is off by default.** The app NSG allows HTTPS (443) only; set `app_enable_http = true` to opt into plain HTTP (e.g. certificate-less demo, or App Gateway in front owning TLS). RDP from the Internet is rejected by variable validation.
- **Tentacle MSI verification:** set `tentacle_msi_sha256` (+ a pinned `tentacle_download_url`) for production images; an empty hash only warns.
- **Windows generalize is one-way.** After `packer build` sysprep-generalizes the VM; don't reuse the build VM. Re-run Packer to produce a new image version. (`winrm_insecure = true` on the ephemeral build VM is acceptable and documented in the template.)
- **Bastion, not public IP.** Public IPs are policy-denied by default (`policy_deny_public_ip = true`); `compute_enable_public_ip` defaults to `false` to match. Reach VMs through Azure Bastion or the mgmt-subnet jump host.
- **First-enforce apply may fail intentionally.** With `policy_enforcement_mode = "Default"`, creating a non-compliant resource is denied — that's the demo. Relax to `"DoNotEnforce"` for an audit-only pass if you must, then flip it back.
- **Octopus provider pin:** the shared range in `providers.tf` is permissive (`>= 0.21, < 2.0`); Stage 3 is verified against v0.43.x. Pin exactly and commit `.terraform.lock.hcl` for reproducible builds.
