# How to Use — MS Migration Factory: Golden Image Prep

A hands-on manual for cloud/platform engineers who want to **run and customize** this PoC. It bakes a golden Windows Server 2022 image (IIS + Octopus Tentacle) with Packer, stands up compliant Azure infrastructure from that image with Terraform + Azure Verified Modules, and maps the resulting VMs into an Octopus Deploy `Dev → Test → Prod` pipeline.

This guide is written against the **actual variables and defaults in the repo**. Every variable name, default, and file path below is real — copy them verbatim.

> **Orientation:** the whole thing is one Terraform root (`terraform/`, one state) plus a standalone Packer build (`packer/`). Variables are namespaced by stage: shared/network in `variables.tf`, compute in `variables.compute.tf`, Octopus in `variables.octopus.tf`, policy also in `variables.tf`. Copy the matching `*.example` tfvars, merge them into a single `terraform/terraform.tfvars`, and keep secrets out of it.

---

## 1. What you need (prerequisites)

| Requirement | Detail |
|-------------|--------|
| **Azure subscription** | A role that can create RGs, networks, VMs **and policy assignments**: Contributor **+ Resource Policy Contributor** (for `policy.tf`) **+ Managed Identity Operator** (for the VM system-assigned identities). |
| **Azure CLI** | `az` ≥ 2.60, signed in: `az login` then `az account set --subscription <id>`. Both Packer and Terraform use this session by default. |
| **Packer** | ≥ 1.9 (`packer version`). The `github.com/hashicorp/azure` plugin auto-installs on `packer init`. |
| **Terraform** | **≥ 1.10** — this is a hard floor (`required_version = ">= 1.10.0"` in `providers.tf`; the pinned AVM compute module `0.21.0` requires it). |
| **azurerm provider** | `~> 4.0` (pinned in `providers.tf`). azurerm 4.x needs a subscription — set `subscription_id`/`tenant_id` in tfvars, or export `ARM_SUBSCRIPTION_ID`/`ARM_TENANT_ID`, or rely on the `az` CLI context. |
| **Octopus Server + API key** | **Only when `enable_octopus_stage = true`.** Cloud (`https://<you>.octopus.app`) or self-hosted, reachable from Azure. An **API key** (`API-…`) able to manage the target Space. With the default `enable_octopus_stage = false` you need none of this — plan/apply of network + compute + policy works with **no reachable Octopus server**. |
| **JFrog Artifactory** | **Only when `image_source = "jfrog"`.** Base URL, the repo path to a generalized Windows VHD, and a read token — plus **PowerShell 7 (`pwsh`) + `az` + native `curl`** on the Terraform runner (the import script needs them). |

**Auth for unattended CI:** instead of `az login`, export a service principal — `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID` for Terraform, and the matching `client_id` / `client_secret` / `tenant_id` / `subscription_id` Packer vars (with `use_azure_cli_auth = false`).

---

## 2. Quickstart (fastest path to a working deployment)

This is the gallery path with the Octopus stage left off — the shortest route to running VMs built from your golden image.

```bash
# 0) One-time: create the Compute Gallery + image definition Packer publishes into.
#    These names are a CONTRACT shared by Packer and Terraform — don't rename one side only.
pwsh ./scripts/00-prereq-gallery.ps1 \
  -ResourceGroup rg-msmf-gallery -GalleryName gal_msmf \
  -Location eastus -ImageDefinition win2022-iis-octopus

# 1) Build the golden image (Windows Server 2022 + IIS + Octopus Tentacle).
cd packer
cp windows-golden-image.pkrvars.hcl.example windows-golden-image.pkrvars.hcl   # edit auth + gallery names
packer init .
packer validate -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl
packer build    -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl
#    → publishes gal_msmf / win2022-iis-octopus : 1.0.0  (into rg-msmf-gallery)

# 2) Build the Azure infra FROM that image (RG + VNet/subnets/NSGs + policy + VMs).
cd ../terraform
cp terraform.tfvars.example terraform.tfvars                 # shared + network + policy values
cat terraform.tfvars.compute.example >> terraform.tfvars     # add the compute values, then edit
terraform init
terraform plan  -out=msmf.tfplan
terraform apply msmf.tfplan
```

With the default `enable_octopus_stage = false`, step 2 plans and applies with **no Octopus connectivity**: resource group, VNet + app/mgmt subnets + NSGs, the Azure Policy compliance baseline (enforced), and `compute_vm_count` VMs from the golden image — each with a system-assigned managed identity, boot diagnostics, and the Tentacle-registration CustomScript extension staged for first boot.

To also stand up Octopus and wire the promotion pipeline, continue to §3e and §4.

> **VMs are private by design.** Public IPs are policy-denied by default and port 80 is off — reach the VMs over the mgmt subnet (jump host / Azure Bastion). See §3a and §3d.

---

## 3. Customization

This is the core of the manual. All variables live in `terraform/variables*.tf`; put your values in `terraform/terraform.tfvars`. Secrets go through `TF_VAR_*` environment variables, never into the file.

### 3a. Customize the network

Declared in `terraform/variables.tf`, consumed by `terraform/network.tf`.

| Variable | Default | What it controls |
|----------|---------|------------------|
| `vnet_address_space` | `["10.10.0.0/16"]` | VNet address space(s). Validated as CIDR(s). |
| `app_subnet_address_prefixes` | `["10.10.1.0/24"]` | App subnet (`snet-app-<env>`) — where the IIS VMs / Tentacles live. |
| `mgmt_subnet_address_prefixes` | `["10.10.2.0/24"]` | Management subnet (`snet-mgmt-<env>`) — jump host / bastion. Also used as the RDP source into the app subnet. |
| `mgmt_rdp_source_cidrs` | `["10.0.0.0/8"]` | Who may RDP (3389) into the mgmt subnet. **Validation rejects `0.0.0.0/0`, `*`, `Internet`, `Any`** — you must supply a specific corporate/VPN range. |
| `app_http_source_prefix` | `"Internet"` | Source for inbound **HTTPS 443** (and HTTP 80 when enabled) to the app subnet. A CIDR or a service tag (`Internet`, `VirtualNetwork`, an App Gateway subnet CIDR). |
| `app_enable_http` | `false` | Opt-in switch for the **plain HTTP (80)** inbound rule. Off = HTTPS-only. |
| `octopus_server_source_cidrs` | `["10.10.0.0/16"]` | Source allowed to reach the **Listening Tentacle port 10933**. Only relevant for Listening Tentacles; unused for the default Polling mode. Override with your Octopus Server IP/CIDR for real Listening use. |

**How the NSG rules map** (built by `network.tf`; priorities are fixed, lower = evaluated first):

*App-subnet NSG* `nsg-app-<env>`:

| Rule | Priority | Port | Source | Present when |
|------|----------|------|--------|--------------|
| `Allow-HTTP-Inbound` | 100 | 80 | `app_http_source_prefix` | only if `app_enable_http = true` |
| `Allow-HTTPS-Inbound` | 110 | 443 | `app_http_source_prefix` | always |
| `Allow-Octopus-Tentacle-10933-Inbound` | 200 | 10933 | `octopus_server_source_cidrs` | always (used only by Listening Tentacles) |
| `Allow-RDP-From-Mgmt-Inbound` | 300 | 3389 | `mgmt_subnet_address_prefixes` | always (jump-host pattern) |
| `Allow-AzureLoadBalancer-Inbound` | 310 | any | `AzureLoadBalancer` | always |
| `Deny-All-Inbound` | 4096 | any | `*` | always (explicit backstop) |

*Management-subnet NSG* `nsg-mgmt-<env>`:

| Rule | Priority | Port | Source |
|------|----------|------|--------|
| `Allow-RDP-Inbound` | 100 | 3389 | `mgmt_rdp_source_cidrs` |
| `Allow-Octopus-Tentacle-10933-Inbound` | 200 | 10933 | `octopus_server_source_cidrs` |
| `Allow-AzureLoadBalancer-Inbound` | 300 | any | `AzureLoadBalancer` |
| `Deny-All-Inbound` | 4096 | any | `*` |

So administrators reach the app VMs **only** by first landing on the mgmt subnet (whose RDP is locked to `mgmt_rdp_source_cidrs`), then RDP-ing across to the app subnet.

**Worked example — re-address the VNet and lock RDP to a corporate CIDR.** Say your enterprise uses `10.50.0.0/16` for this landing zone and your admins connect from the office range `203.0.113.0/24`:

```hcl
# terraform/terraform.tfvars
vnet_address_space           = ["10.50.0.0/16"]
app_subnet_address_prefixes  = ["10.50.10.0/24"]   # IIS VMs
mgmt_subnet_address_prefixes = ["10.50.20.0/24"]   # jump host

# Only the office egress range may RDP into mgmt. (Leaving 10.0.0.0/8 or
# using 0.0.0.0/0 here would fail variable validation.)
mgmt_rdp_source_cidrs = ["203.0.113.0/24"]

# Front the app with HTTPS only, reachable from anywhere (or narrow this too):
app_http_source_prefix = "Internet"
app_enable_http        = false
```

Because `Allow-RDP-From-Mgmt-Inbound` sources from `mgmt_subnet_address_prefixes`, re-addressing the mgmt subnet automatically re-scopes app-VM RDP — you don't edit two places.

### 3b. Choose the image source

`terraform/compute.tf` reads exactly one source, selected by `image_source` (declared in `variables.compute.tf`). Both paths converge on the same internal image id, so the VM definition is identical either way.

**Gallery (default, recommended)** — `image_source = "gallery"`. Resolves a Compute Gallery image version. The gallery coordinates default to **exactly what Packer publishes**:

```hcl
image_source                        = "gallery"
compute_compute_gallery_name        = "gal_msmf"               # == Packer gallery_name
compute_image_definition_name       = "win2022-iis-octopus"    # == Packer image_definition_name
compute_image_version               = "latest"                 # or a pinned "1.0.20260718"
compute_gallery_resource_group_name = "rg-msmf-gallery"        # == Packer gallery_resource_group
compute_image_hyper_v_generation    = "V2"
```

> These three gallery names are a **cross-stage contract** with Packer (`packer/variables.pkr.hcl`). Rename them on **both** sides or the `data.azurerm_shared_image_version` lookup finds nothing.

**JFrog Artifactory** — `image_source = "jfrog"`. The VHD is streamed out of Artifactory, staged as a page blob, and wrapped as a managed image before the VMs are built. Requires `pwsh` + `az` + `curl` on the runner.

```hcl
image_source                       = "jfrog"
jfrog_base_url                     = "https://acme.jfrog.io/artifactory"
jfrog_repo_path                    = "golden-images-vhd/win2022-iis-octopus/osdisk.vhd"
jfrog_staging_storage_account_name = "stmsmfvhdstaging"   # must already exist
jfrog_staging_resource_group_name  = "rg-msmf-gallery"    # null => workload RG
jfrog_staging_container            = "vhds"
jfrog_vhd_blob_name                = "win2022-iis-octopus-osdisk.vhd"
compute_jfrog_os_disk_size_gb      = 127                  # >= the VHD's virtual size
```

Credentials are **sensitive** and passed via environment, never in tfvars — token preferred:

```bash
export TF_VAR_jfrog_access_token='<artifactory-identity-token>'
# or basic auth:
export TF_VAR_jfrog_username='ci-reader'
export TF_VAR_jfrog_password='<password-or-api-key>'
```

`jfrog_access_token` takes precedence over `jfrog_username`/`jfrog_password`.

### 3c. Size the compute

Declared in `terraform/variables.compute.tf`.

| Variable | Default | Notes |
|----------|---------|-------|
| `compute_vm_count` | `2` | Number of VMs from the golden image. Whole number ≥ 1. |
| `compute_vm_size` | `Standard_D2s_v5` | Azure VM SKU. |
| `compute_vm_name_prefix` | `vm-msmf` | Names become `vm-msmf-01`, `-02`, … **Validated**: 2–13 chars, lowercase alphanumeric/hyphen, starts with a letter (keeps Windows computer names ≤ 15). |
| `compute_availability_zones` | `["1","2","3"]` | Zones VMs round-robin across. Use a single-element list in one-zone regions. |
| `compute_os_disk_storage_account_type` | `Premium_LRS` | Managed-disk SKU. |
| `compute_enable_public_ip` | `false` | Keep VMs private. If you set `true`, you must also set `policy_deny_public_ip = false` (§3d) or the policy blocks the NIC. |
| `compute_boot_diagnostics_storage_uri` | `null` | `null` = Azure-managed diagnostics storage (recommended). |

**Admin credentials (sensitive).** Username is a normal var; the password comes through the environment or is auto-generated:

```hcl
compute_admin_username = "msmfadmin"   # reserved names (administrator/admin/root/guest) are rejected
# compute_admin_password: DO NOT put it here.
```

```bash
# Option A — supply it (e.g. from Key Vault):
export TF_VAR_compute_admin_password=$(az keyvault secret show \
  --vault-name kv-msmf-secrets --name vm-admin-password --query value -o tsv)
# Option B — leave compute_admin_password unset (null) and the AVM module generates one.
```

> **State note:** either way the resolved password lands in Terraform state (auto-generated included). Use an encrypted remote backend and rotate anything that passed through a local/demo state file.

### 3d. Compliance — the security-compliance baseline (Azure Policy)

`terraform/policy.tf` implements the compliance baseline in **two layers**:

**Layer A — a recognized built-in initiative.** The compliance baseline is
mapped to a recognized Azure built-in Policy Initiative, assigned at the workload
resource-group scope so the customer sees an audit-recognizable standard being
enforced — not an invented one. Selectable with one variable:

| Variable | Default | Effect |
|----------|---------|--------|
| `compliance_initiative` | `"mcsb"` | Which recognized initiative the compliance baseline maps to: `mcsb` = **Microsoft Cloud Security Benchmark**, `cis` = CIS Microsoft Azure Foundations Benchmark v2.0.0, `nist` = NIST SP 800-53 Rev. 5, `iso27001` = ISO 27001:2013, `none` = skip (deny controls only). The assignment gets a system-assigned identity + a Contributor grant on the RG so its DeployIfNotExists/Modify controls can remediate. |

> When an organization-specific control set is supplied, replace or extend this baseline so the assignments carry those control IDs. The scaffold is designed for that swap.

**Layer B — targeted deny controls** (enforcement teeth the audit-only initiative
does not give). Knobs (in `variables.tf`):

| Variable | Default | Effect |
|----------|---------|--------|
| `policy_enforcement_mode` | `"Default"` | `"Default"` = **enforced** (deny effects block non-compliant creates). `"DoNotEnforce"` = audit-only dry run. Validated to those two values. |
| `policy_allowed_locations` | `["eastus","eastus2"]` | Regions resources may be created in (**Deny**). Keep in sync with `location` and Packer's `replication_regions`. |
| `policy_required_tag_keys` | `["project","env","owner"]` | One "require a tag" assignment **per key** (**Deny**). These three are exactly what the module tags every resource with, so compliant by construction. |
| `policy_deny_public_ip` | `true` | Assign "NICs should not have public IPs" (**Deny**). Set `false` only if `compute_enable_public_ip = true` is genuinely needed. |
| `policy_require_disk_encryption` | `true` | Assign the VM disk-encryption **audit** policy (`AuditIfNotExists`, not deny). |

The subnet-NSG control is always assigned as `AuditIfNotExists` (the built-in has no deny variant); `network.tf` already associates an NSG with each subnet, so it reports compliant.

Tuning examples:

```hcl
# Audit-only first pass (see what WOULD be denied without blocking the apply):
policy_enforcement_mode = "DoNotEnforce"

# Add a region and an extra required tag:
policy_allowed_locations = ["eastus", "eastus2", "westeurope"]
policy_required_tag_keys = ["project", "env", "owner", "cost_center"]

# Allow public IPs (must pair with compute_enable_public_ip = true):
policy_deny_public_ip    = false
compute_enable_public_ip = true
```

> With enforcement on, creating an untagged resource or a public IP in the RG is **denied** — that's the demo, not a bug. Flip to `"DoNotEnforce"` only for an exploratory pass, then flip it back.

### 3e. Octopus — environments and the promotion pipeline

Connection inputs are shared (`variables.tf`); the rest are namespaced `octopus_*` (`variables.octopus.tf`). **Nothing Octopus-side is created — and no Octopus server is contacted — until `enable_octopus_stage = true`.**

```hcl
# terraform/terraform.tfvars
enable_octopus_stage = true
octopus_server_url   = "https://your-octopus.octopus.app"
octopus_space_id     = "Spaces-1"
# octopus_api_key -> environment only:
```
```bash
export TF_VAR_octopus_api_key='API-XXXXXXXXXXXXXXXXXXXXXX'
```

Stage-3 shape (all with sensible defaults):

| Variable | Default | Controls |
|----------|---------|----------|
| `octopus_dev_environment_name` | `Development` | Dev environment name. |
| `octopus_test_environment_name` | `Test` | Test environment name. |
| `octopus_prod_environment_name` | `Production` | Prod environment name. |
| `octopus_project_name` | `MSMF Golden Image App` | Octopus project. |
| `octopus_project_group_name` | `MS Migration Factory` | Project group. |
| `octopus_lifecycle_name` | `MSMF Dev-Test-Prod` | Sequential lifecycle (no phase skippable). |
| `octopus_target_roles` | `["iis-web-server"]` | Role the deploy step targets. **Must be a subset of** `compute_octopus_target_roles` (default `["msmf-web","iis-web-server"]`) so self-registered VMs are selected. |
| `octopus_package_id` | `MSMF.GoldenImage.WebApp` | Package CI pushes to the built-in feed. |
| `octopus_iis_website_name` / `octopus_iis_app_pool_name` | `MSMFGoldenImageApp` | IIS site / app pool the deploy creates. |
| `octopus_iis_binding_port` | `"80"` | IIS HTTP binding port. |
| `octopus_deployment_targets` | `[]` | Leave empty to rely on VM **self-registration** (recommended for golden images). Populate only for an explicit fixed fleet with known thumbprints. |

**Environment mapping is a single source of truth.** The compute stage derives which environment a VM registers into from the *same* `octopus_*_environment_name` variables: shared `environment = dev` → `octopus_dev_environment_name` (`Development`), `test` → `Test`, `prod` → `Production`. So out of the box the environment a Tentacle registers into always exists. Override only for a non-standard mapping via `compute_octopus_environment`.

---

## 4. Everyday tasks

### Build a new golden-image version

Bump the version and rebuild — the gallery keeps every version:

```bash
cd packer
# edit windows-golden-image.pkrvars.hcl:  image_version = "1.0.1"   (MAJOR.MINOR.PATCH, validated)
packer build -var-file=windows-golden-image.pkrvars.hcl windows-golden-image.pkr.hcl
```

If Terraform uses `compute_image_version = "latest"`, the next `terraform apply` picks up the new version and re-images on the next VM replacement. To control exactly when VMs move, pin `compute_image_version = "1.0.1"` instead of `"latest"`.

> For production images, pin the Tentacle supply chain: set `tentacle_download_url` to a specific version and `tentacle_msi_sha256` to its checksum — the build then **fails hard** on any hash mismatch. An empty hash installs with a warning only.

### Deploy the app through Dev → Test → Prod

The CI/CD pipelines (`pipelines/azure-pipelines.yml` or `pipelines/github-actions-deploy.yml`) do: `dotnet publish` → pack `MSMF.GoldenImage.WebApp.<ver>.nupkg` → push to the Octopus built-in feed → create release → deploy **Development** → gated promotion to **Test** → **Production**.

- **Azure DevOps:** set pipeline variables `OctopusServerUrl`, `OctopusSpace` and secret `OctopusApiKey`; create ADO Environments `MSMF-Development/-Test/-Production` with approvals on Test/Prod.
- **GitHub Actions:** set repo variables `OCTOPUS_SERVER_URL`, `OCTOPUS_SPACE`, secret `OCTOPUS_API_KEY`; add GitHub Environments `Development/Test/Production` with required reviewers on Test/Prod.

Human approval gates live in the pipeline platform. The Octopus lifecycle enforces **sequence** (a release must land in Development, then Test, before Production is reachable) but not sign-off. The deploy step targets the `iis-web-server` **role**, so new VMs are picked up automatically once they self-register — you never name machines in the pipeline.

### Add a VM

Scale the pool and apply:

```hcl
# terraform/terraform.tfvars
compute_vm_count = 4
```
```bash
cd terraform
terraform apply -var 'enable_octopus_stage=true'   # keep the flag as-is for your state
```

New VMs (`vm-msmf-03`, `-04`) are created from the same golden image, self-register their Tentacles into the mapped environment with roles `["msmf-web","iis-web-server"]`, and become deploy targets automatically. VM names, private IPs, and managed-identity principal ids are available in the `compute_*` outputs (`outputs.compute.tf`).

> **Keep `enable_octopus_stage` consistent** across applies of the same state. Turning it back off plans to **destroy** the Octopus resources (which then needs a reachable server).

---

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `terraform plan` fails with an Octopus **auth / DNS** error | `enable_octopus_stage = true` but `octopus_server_url` / `octopus_api_key` aren't real. | Either set `enable_octopus_stage = false` (network + compute plan with no Octopus), or supply a real URL + `TF_VAR_octopus_api_key`. |
| `data.azurerm_shared_image_version.golden` — **image version not found** | Gallery names differ between Packer and Terraform, the image wasn't built yet, or the wrong RG. | Confirm Packer published the version, and that `compute_compute_gallery_name` / `compute_image_definition_name` / `compute_gallery_resource_group_name` match `packer/variables.pkr.hcl` exactly. Run `scripts/00-prereq-gallery.ps1` if the definition is missing. |
| `mgmt_rdp_source_cidrs must not open RDP to the Internet` | You put `0.0.0.0/0`, `*`, `Internet`, or `Any` in `mgmt_rdp_source_cidrs`. | Supply a specific corporate/VPN CIDR (see the §3a worked example). |
| Apply **denied**: missing tag / disallowed location / public IP not allowed | the compliance baseline is enforced (`policy_enforcement_mode = "Default"`). | That's the compliance control working. Fix the resource, or set `policy_enforcement_mode = "DoNotEnforce"` for an audit-only pass, then flip back. For a needed public IP, set `policy_deny_public_ip = false` **and** `compute_enable_public_ip = true` together. |
| VM boots but the **Tentacle-registration extension reports a failure** | The registration script dialed `octopus_server_url` before any Octopus server/environment existed. | Stand up Stage 3 first (`terraform apply -var 'enable_octopus_stage=true'`), then re-apply / re-run the extension. For a clean end-to-end demo, apply the Octopus stage before or with the compute stage. |
| `Error: unsupported Terraform Core version` / module needs ≥ 1.10 | CLI older than the `>= 1.10.0` floor. | Upgrade Terraform to ≥ 1.10. |
| JFrog import step fails (`pwsh` / `az` / `curl` not found, or 401) | Runner is missing PowerShell 7 / Azure CLI / curl, or the token is wrong. | Install `pwsh` + `az` + `curl` on the runner; export `TF_VAR_jfrog_access_token` (or `TF_VAR_jfrog_username`/`_password`). Confirm `jfrog_base_url` + `jfrog_repo_path` resolve to the VHD, and the staging storage account exists. |
| `compute_vm_name_prefix must be 2-13 chars…` | Prefix too long / uppercase / doesn't start with a letter. | Use a short lowercase prefix (e.g. `vm-msmf`) so `<prefix>-NN` stays ≤ 15 chars for Windows. |
| Turning off `enable_octopus_stage` plans a big **destroy** | The flag is a lifecycle switch, not a feature flag. | Keep it `true` once Stage 3 exists in the state; only turn it off when you deliberately want the Octopus resources gone (which needs server connectivity). |
| Can't browse the app after deploy | Public IPs are policy-denied and port 80 is off by default. | Reach the VM's **private** IP over the mgmt subnet (jump host / Azure Bastion). To expose plain HTTP for a quick demo, set `app_enable_http = true`. |

---

### Where each value lives (quick reference)

- **Non-secret config** → `terraform/terraform.tfvars` (merge the three `*.example` files).
- **Secrets** → `TF_VAR_*` from Key Vault / a CI secret store: `TF_VAR_octopus_api_key`, `TF_VAR_compute_admin_password`, `TF_VAR_jfrog_access_token` (or `_username`/`_password`).
- **Packer secrets** → `PKR_VAR_client_secret`, `PKR_VAR_octopus_api_key`; `*.pkrvars.hcl` is git-ignored.
- **App runtime secrets** → Octopus sensitive variables, never in Terraform or Git.

Add `terraform.tfvars`, `*.pkrvars.hcl`, `*.tfplan`, `.terraform/`, and `*.tfstate*` to `.gitignore`, and use an encrypted remote backend (uncomment the `backend "azurerm"` stub in `providers.tf`) before any real run — Terraform state for this root contains secrets.
