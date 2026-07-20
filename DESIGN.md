# MS Migration Factory — Golden Image Prep: Solution Design

> **Project tag:** `project = msmf-golden-image` · **Region default:** East US · **Audience:** cloud / platform engineers evaluating the Migration Factory pattern on Azure.
>
> This document describes the design of a runnable three-stage proof of concept. It is accurate to the code in this repository: Packer templates under `packer/`, a single Terraform root module under `terraform/`, PowerShell provisioners under `scripts/`, CI/CD definitions under `pipelines/`, and the sample application under `src/MSMF.GoldenImage.WebApp/`.

---

## 1. Executive summary

Server migrations and greenfield workload rollouts repeatedly hit the same three problems: hand-built servers drift from one another and from their documentation, the infrastructure that hosts them is re-created inconsistently by whoever is on shift, and getting application code onto those servers is a manual, error-prone hand-off. The **Migration Factory** pattern solves this by turning the workload into a repeatable production line: **standardize the operating system and its agents into an immutable, versioned golden image once; reproduce that image on demand as compliant, policy-enforced Azure infrastructure with Terraform; and wire every resulting VM straight into a promotion-based (Dev → Test → Prod) deployment pipeline** so application releases flow to a role, not to a named machine. This PoC implements that line end to end for a classic IIS web workload — Packer bakes a Windows Server 2022 image with IIS and an Octopus Deploy Tentacle, Terraform (using Azure Verified Modules) stands up the network and VMs from that image under an enforced the compliance baseline Azure Policy baseline, and Octopus Deploy plus a CI/CD pipeline carry the sample ASP.NET Core app through gated environments — with everything parameterized and no secrets committed to source.

---

## 2. Architecture overview

The solution is three stages joined by two well-defined artifact hand-offs: a **golden image** (Packer → gallery/JFrog) and a set of **self-registering deployment targets** (Terraform VMs → Octopus). Terraform Stages 2 and 3 are a single root module with one state file; the Octopus stage is isolated *logically* by the `enable_octopus_stage` flag rather than by a separate state root.

```
  STAGE 1 — GOLDEN IMAGE                         Packer (azure-arm builder)
  packer/windows-golden-image.pkr.hcl
  ┌───────────────────────────────────────────────────────────────────────┐
  │ Windows Server 2022 (Gen2) base image  [MicrosoftWindowsServer /       │
  │                                          WindowsServer / 2022-datacenter-g2]
  │   1. install-iis.ps1              IIS Web-Server + ASP.NET 4.x + mgmt   │
  │                                   tools + health page (health.html)     │
  │   2. windows-restart                                                    │
  │   3. install-octopus-tentacle.ps1 download + SHA256-verify + install    │
  │                                   Tentacle MSI; registration STAGED,    │
  │                                   NOT performed (generalized image)     │
  │   4. Sysprep /generalize          reseal to OOBE, then capture          │
  └───────────────────────────────┬───────────────────────────────────────┘
                                   │  capture (generalized)
                                   ▼
        Azure Compute Gallery image VERSION
        rg-msmf-gallery / gal_msmf / win2022-iis-octopus : 1.0.x
                                   │
      image_source = "gallery"     │      image_source = "jfrog"
      (default)                    │      VHD in JFrog Artifactory
                                   │         scripts/import-jfrog-vhd.ps1:
                                   │         curl (creds via stdin) → page blob
                                   │         → azurerm_image (managed image)
                                   ▼                         ▼
  STAGE 2 — AZURE INFRA               Terraform + Azure Verified Modules
  terraform/  (ONE root module, ONE state)
  ┌───────────────────────────────────────────────────────────────────────┐
  │ network.tf  Resource group  (AVM avm-res-resources-resourcegroup)      │
  │             VNet + app/mgmt subnets (AVM avm-res-network-virtualnetwork)│
  │             2 subnet NSGs   (AVM avm-res-network-networksecuritygroup)  │
  │ compute.tf  N Windows VMs FROM the golden image                        │
  │             (AVM avm-res-compute-virtualmachine 0.21.0)                 │
  │               • system-assigned managed identity                       │
  │               • boot diagnostics (managed)                             │
  │               • CustomScript extension → register-octopus-tentacle.ps1 │
  │ policy.tf   Azure Policy compliance baseline (ENFORCED by default)     │
  └───────────────────────────────┬───────────────────────────────────────┘
                                   │  each VM's Tentacle self-registers on
                                   │  first boot with role(s) + environment
                                   ▼
  STAGE 3 — OCTOPUS + CI/CD           octopus.tf  (gated: enable_octopus_stage)
  ┌───────────────────────────────────────────────────────────────────────┐
  │ Environments  Development ──► Test ──► Production                       │
  │ Lifecycle (sequential) + Project Group + Project + Deployment Process   │
  │ Deployment targets = the Stage-2 VMs, selected by role "iis-web-server" │
  └───────────────────────────────┬───────────────────────────────────────┘
                                   │
  pipelines/azure-pipelines.yml  |  pipelines/github-actions-deploy.yml
                                   ▼
   dotnet publish → pack MSMF.GoldenImage.WebApp.<ver>.nupkg → push to the
   Octopus built-in feed → create release → deploy Development
        → (approval) Test → (approval) Production
```

**Cross-stage contracts that make the hand-offs work:**

- **Gallery coordinates** — `rg-msmf-gallery` / `gal_msmf` / `win2022-iis-octopus` are the shared defaults of *both* `packer/variables.pkr.hcl` (`gallery_resource_group` / `gallery_name` / `image_definition_name`) *and* `terraform/variables.compute.tf` (`compute_gallery_resource_group_name` / `compute_compute_gallery_name` / `compute_image_definition_name`). Terraform's `data.azurerm_shared_image_version.golden` therefore resolves exactly what Packer publishes.
- **Environment names** — the `octopus_dev/test/prod_environment_name` variables are the single source of truth for both the environments Stage 3 *creates* and the environment each VM *self-registers into* (compute maps the shared `environment` `dev|test|prod` onto those same names). A `dev` deployment always registers into an environment ("Development") that exists.
- **Roles** — compute registers each Tentacle with `compute_octopus_target_roles` (default `["msmf-web","iis-web-server"]`); the deployment process targets `octopus_target_roles` (default `["iis-web-server"]`), a subset — so the step selects exactly those VMs and never names a machine.

---

## 3. Design decisions & rationale

### 3.1 Why Packer for the golden image

The unit of standardization is an **immutable, versioned OS artifact**, not a configuration script that runs against a live server. Packer's `azure-arm` builder produces a generalized (Sysprep'd) Windows image and publishes it as an Azure Compute Gallery image *version*, so every downstream VM is byte-identical and traceable to a specific build. The build is auditable and reproducible: provisioners run in a fixed order against an ephemeral build VM in its own temporary resource group (auto-created and torn down unless `build_resource_group_name` is set), and a `manifest` post-processor writes `packer-build-manifest.json` recording the gallery, definition, version, base image and build timestamp. Baking IIS and the Tentacle in once means no per-VM feature installation, no drift, and a supply chain that can be verified at build time (see §4.4) rather than trusted at run time.

### 3.2 Why Azure Verified Modules instead of raw `azurerm`

The infra stage composes official **Azure Verified Modules (AVM)** from the Terraform Registry rather than hand-rolling every `azurerm` resource. AVM modules are Microsoft-maintained, versioned building blocks that encode Well-Architected defaults (naming, tagging, identity, diagnostics, telemetry toggles) and are supportable and upgradeable over time — the durability a "factory" needs to scale from one workload to hundreds. Concretely, using AVM removes boilerplate that is easy to get wrong: `avm-res-network-virtualnetwork` creates subnets inline and associates each NSG by `resource_id`, so no separate `azurerm_subnet_network_security_group_association` is required; `avm-res-compute-virtualmachine` wires the NIC, managed identity, boot diagnostics and CustomScript extension through a single typed interface.

Where **no suitable AVM module exists**, the design falls back to raw `azurerm` *deliberately and in a documented way*, rather than forcing an ill-fitting module:

- **JFrog VHD import** — there is no AVM module for "import an external VHD as a managed image", so `compute.tf` uses `terraform_data` (local-exec) + `azurerm_image`.
- **Azure Policy baseline** — the full ALZ policy experience lives in the management-group-scale `Azure/avm-ptn-alz` pattern module; for a resource-group-scoped PoC baseline, per-control `azurerm_resource_group_policy_assignment` resources are clearer and cheaper to reason about (see §4).
- **Octopus resources** — the `octopusdeploy` provider is outside AVM's scope (AVM is Azure-only).

### 3.3 Why the `gallery` OR `jfrog` image-source toggle

Enterprises adopting a Migration Factory rarely start from a blank slate — many already keep golden VHDs in an existing artifact estate such as **JFrog Artifactory**. The single toggle `image_source = "gallery" | "jfrog"` (declared in `variables.compute.tf`, validated to those two values) proves the same factory can consume either source with **zero change to the compute code**. Both paths converge on one local, `local.compute_source_image_id`, which is the only thing handed to the VM module:

```hcl
compute_source_image_id = (
  var.image_source == "gallery"
  ? one(data.azurerm_shared_image_version.golden[*].id)   # gallery version
  : one(azurerm_image.jfrog[*].id)                         # JFrog-derived managed image
)
```

The gallery path is the default and recommended (Azure-native, replicated, versioned). The JFrog path streams the VHD into a staging page blob and wraps it as a generalized managed image before compute runs. This keeps the migration approach pluggable without branching the VM definition.

### 3.4 Why `enable_octopus_stage` gates the whole Octopus stage

A platform team must be able to plan and apply the **network and compute** independently of any Octopus server — for a first landing-zone build, for a customer who has no Octopus instance yet, or simply to keep `terraform plan` in CI fast and connectivity-free. The challenge is that Terraform reads *data sources* (e.g. `octopusdeploy_feeds`, `octopusdeploy_machine_policies`) at **plan** time, which would otherwise force a live connection even when no Octopus resources are being created. The design solves this by putting `count = var.enable_octopus_stage ? 1 : 0` (or an equivalently gated `for_each`) on **every** octopusdeploy resource *and data source*, keeping all cross-references count-indexed (`octopusdeploy_project.this[0]`) and wrapping the `octopus_*` outputs in `one()`/`try()` so they return `null`/`{}` while the stage is off. With the default `enable_octopus_stage = false`, plan/apply/destroy of network + compute never contact Octopus and the placeholder `octopus_server_url` / empty `octopus_api_key` defaults are sufficient. It is important to treat this as a *lifecycle* switch, not a feature flag: turning it off on a state that already has Octopus resources plans their destruction.

### 3.5 Why Tentacle registration is staged in the image, not baked

`install-octopus-tentacle.ps1` installs the Tentacle MSI and stages the registration script into the image, but — by default (`octopus_register_during_build = false`) — it does **not** create the Tentacle instance, generate a certificate, or register with the server during the Packer build. This is the critical golden-image correctness decision: a generalized image is cloned to many VMs, so if the certificate/thumbprint and registration were baked in, **every clone would share one identity and collide in Octopus**. Instead, registration is deferred to **first boot**: Stage 2's CustomScript extension runs `register-octopus-tentacle.ps1`, which creates a **unique certificate per VM** (`new-certificate --if-blank`), configures the comms style, installs the Windows service, and registers the machine into the correct Space / Environment / Role(s). The script is idempotent (guarded by a per-instance marker; `register-with --force`), and `register_during_build = true` remains available only for a throwaway single-VM demo.

---

## 4. Security & compliance design

Security is designed in at three layers — **Azure Policy** (what may exist in the resource group), **NSGs** (what may reach the VMs), and **secret/state handling** (how credentials are passed and persisted).

### 4.1 the Azure Policy compliance baseline (`terraform/policy.tf`)

`policy.tf` assigns **built-in** policy definitions at the **workload resource-group scope** (`module.resource_group.resource_id`), one `azurerm_resource_group_policy_assignment` per control. Built-ins are resolved by their canonical immutable GUID via `data "azurerm_policy_definition"` (more robust than display-name matching, which has broken on punctuation changes), and the plan-time lookup also validates the definition exists.

| # | Control | Effect | Backing built-in (GUID) | Knob / default |
|---|---------|--------|-------------------------|----------------|
| 1 | **Require tags** `project`, `env`, `owner` (one assignment per key) | **Deny** | Require a tag on resources (`871b6d14-…`) | `policy_required_tag_keys` = `["project","env","owner"]` |
| 2 | **Allowed locations** | **Deny** | Allowed locations (`e56962a6-…`) | `policy_allowed_locations` = `["eastus","eastus2"]` |
| 3 | **Deny public IPs on NICs** | **Deny** | Network interfaces should not have public IPs (`83a86a26-…`) | `policy_deny_public_ip` = `true` (opt-out) |
| 4 | **NSG on every subnet** | **AuditIfNotExists** | Subnets should be associated with an NSG (`e71308d3-…`) | always on (built-in has no deny variant) |
| 5 | **Disk-encryption audit** | **AuditIfNotExists** | Windows VMs should enable Azure Disk Encryption or EncryptionAtHost (`3dc5edcd-…`) | `policy_require_disk_encryption` = `true` |

Design notes that make the baseline coherent with the rest of the stack:

- **Enforcement is ON by default.** `policy_enforcement_mode = "Default"` maps to `enforce = true`, so deny effects actually block non-compliant creates. A baseline that ships disabled demonstrates nothing; `"DoNotEnforce"` exists only for an audit-only dry run and should be flipped back.
- **The required tags are exactly what the stack applies.** `providers.tf` builds `local.common_tags` with `project` / `env` / `owner` (plus `managed_by`, `workload`), so every AVM resource satisfies control #1 by construction.
- **Deny-public-IP is matched to compute defaults.** `compute_enable_public_ip` defaults to `false`, so the deny policy and the compute posture agree out of the box; the `policy_deny_public_ip` flag exists so that an exception (e.g. a Listening Tentacle that needs inbound reachability) is an explicit, reviewable tfvars line rather than a silent gap.
- **Control #4 proves, rather than fixes.** `network.tf` already associates an NSG with each subnet, so the audit control is a compliance *proof point* for the demo; it is AuditIfNotExists because the built-in offers no deny variant.
- **No `identity` blocks** are attached to the assignments — a managed identity is only needed for DeployIfNotExists/Modify remediation, and every control here is Deny or AuditIfNotExists, which evaluate without one.

### 4.2 NSG rules (`terraform/network.tf`)

Two subnets, each with its own NSG, are built by `avm-res-network-networksecuritygroup`. Rules are keyed maps (not lists) so a rule can be added or removed later without renumbering the rest.

**Application subnet NSG** (`nsg-app-<env>`):

| Priority | Rule | Port | Source | Notes |
|---------:|------|------|--------|-------|
| 100 | Allow-HTTP-Inbound | 80 | `app_http_source_prefix` | **Only created when `app_enable_http = true`** — HTTP is opt-in |
| 110 | Allow-HTTPS-Inbound | 443 | `app_http_source_prefix` | HTTPS-only posture by default |
| 200 | Allow-Octopus-Tentacle | 10933 | `octopus_server_source_cidrs` | Listening Tentacles only; unused for Polling |
| 300 | Allow-RDP-From-Mgmt | 3389 | `mgmt_subnet_address_prefixes` | Jump-host pattern — RDP only from the mgmt subnet |
| 310 | Allow-AzureLoadBalancer | * | `AzureLoadBalancer` | Health probes for LB/VMSS scenarios |
| 4096 | Deny-All-Inbound | * | * | Explicit defense-in-depth backstop |

**Management subnet NSG** (`nsg-mgmt-<env>`): Allow-RDP (3389) from `mgmt_rdp_source_cidrs` only (priority 100), the same Tentacle-10933 and AzureLoadBalancer allowances, and the same 4096 Deny-All backstop.

Two baseline rules are enforced by **variable validation**, not merely by convention:

- **RDP is never open to the Internet.** `mgmt_rdp_source_cidrs` rejects `0.0.0.0/0`, `*`, `Internet`, and `Any` at plan time.
- **Plain HTTP (80) is off unless explicitly opted in** via `app_enable_http`; the default posture is HTTPS-only (or an App Gateway that terminates TLS in front). Reach VMs through Azure Bastion or the mgmt-subnet jump host — public IPs are policy-denied.

The Tentacle port model is consistent across the stack: **Polling (TentacleActive)** is the default (target dials out to the server on 10943, needs no inbound rule and is cloud-friendly); **Listening (TentaclePassive)** requires the inbound 10933 rule and a server thumbprint to trust.

### 4.3 Secret handling — variables, Key Vault, and `protected_settings`

The golden rule enforced throughout: **non-secret config lives in `terraform.tfvars`; secrets are surfaced as `TF_VAR_*` at apply time from Key Vault or a CI secret store; application runtime secrets live in Octopus sensitive variables** — never in Terraform or Git.

- **Sensitive variables** (`octopus_api_key`, `compute_admin_password`, `jfrog_access_token` / `jfrog_username` / `jfrog_password`, Packer's `client_secret` / `octopus_api_key`) are declared `sensitive = true` so CLI/plan output is redacted, and default to empty/null so nothing is required in code.
- **Octopus API key into the VM extension.** The entire Tentacle-registration command — including `-ApiKey '…'` — is placed **exclusively** in the CustomScript extension's `protected_settings` (`commandToExecute`), which Azure encrypts at rest and never returns via portal/CLI/ARM. The plain `settings` block carries only a re-run trigger hash computed from the script + **non-secret** args (`compute_tentacle_args` deliberately excludes the API key), so no secret-derived material ever appears unencrypted. The key is passed only as a runtime parameter, so it is never written to the script file on disk, and both PowerShell scripts mask it in their transcripts.
- **JFrog credentials never touch argv.** `import-jfrog-vhd.ps1` receives credentials as environment variables from Terraform and hands them to `curl` as a **config document on stdin** (`--config -`), because a running process's command line is readable by any other process on a CI runner and the VHD download runs for minutes. Bearer token is preferred over basic auth.
- **Pull secrets from Key Vault at apply time**, e.g. `export TF_VAR_octopus_api_key=$(az keyvault secret show --vault-name kv-msmf-secrets --name octopus-api-key --query value -o tsv)`.

### 4.4 Supply-chain integrity

`install-octopus-tentacle.ps1` downloads the Tentacle MSI and, when `tentacle_msi_sha256` is set, computes the file's SHA256 and **fails the build hard on any mismatch** *before* the MSI runs as SYSTEM and is cloned fleet-wide. An empty hash installs with a loud warning only. For production images, pin `tentacle_download_url` to a specific version and always set its checksum.

### 4.5 State hygiene

Terraform state for this root **contains secrets** and must be treated as secret material — this is called out explicitly because both `sensitive` and Terraform `ephemeral` cannot solve it here (the values must persist into provider/extension attributes):

- The Octopus API key persists verbatim in state via the extension's `protected_settings` (encrypted at rest in Azure, but plaintext in `terraform.tfstate`).
- When `compute_admin_password` is left `null`, the AVM VM module **generates** a local-admin password — also written to state.

The design's non-negotiables for anything beyond a throwaway demo: (1) use the **remote, encrypted, RBAC-controlled** `backend "azurerm"` (a ready-to-uncomment stub with `use_azuread_auth = true` is in `providers.tf`) and never run with local state; (2) **rotate the Octopus API key** after provisioning, using a dedicated registration-scoped service account; (3) for production, keep the key out of Terraform entirely — have each VM pull it from **Key Vault using its system-assigned managed identity** at boot (grant `Key Vault Secrets User` to the principal ids exported by `outputs.compute.tf`), an IMDS + Key Vault REST sketch is embedded in `compute.tf` comments.

---

## 5. Azure Verified Modules used

All infra resources in Stage 2 are composed from official AVM modules. The pins below are the version constraints **as coded** in the `.tf` files; the versions that `terraform init` resolved into the committed lock are shown alongside for reference.

| Purpose | AVM module | Constraint (as coded) | Resolved | Used in |
|---------|-----------|-----------------------|----------|---------|
| Workload resource group | `Azure/avm-res-resources-resourcegroup/azurerm` | `>= 0.1.0, < 1.0.0` | 0.4.0 | `network.tf` (`module.resource_group`) |
| Subnet NSGs (app + mgmt) | `Azure/avm-res-network-networksecuritygroup/azurerm` | `>= 0.2.0, < 1.0.0` | 0.5.1 | `network.tf` (`module.nsg_app`, `module.nsg_mgmt`) |
| VNet + subnets (+ NSG association) | `Azure/avm-res-network-virtualnetwork/azurerm` | `>= 0.4.0, < 1.0.0` | 0.19.0 | `network.tf` (`module.vnet`) |
| Windows VM(s) from the golden image | `Azure/avm-res-compute-virtualmachine/azurerm` | `0.21.0` (exact) | 0.21.0 | `compute.tf` (`module.vm`, `for_each` over instances) |

The compute module is pinned exactly because it drives the whole floor of the stack: it requires **Terraform >= 1.10** (declared as `required_version` in `providers.tf`) and **azurerm >= 3.116, < 5.0** (satisfied by the `~> 4.0` pin), and it transitively pulls `azapi` / `tls` / `random` / `modtm` / `avm-utl-interfaces` so the root needs no extra provider blocks for them. After the first `terraform init`, commit `.terraform.lock.hcl` so every run resolves identical module and provider builds.

**Raw `azurerm` used by design (no suitable AVM module):** `azurerm_image` + `terraform_data` for the JFrog VHD import (`compute.tf`), and the five `azurerm_resource_group_policy_assignment` resources for the compliance baseline (`policy.tf`). The `octopusdeploy` provider (Stage 3) is outside AVM entirely.

---

## 6. Extensibility

The design is parameterized so a platform team can adapt each dimension without editing resource code. Variables are namespaced per stage (`compute_*`, `jfrog_*`, `octopus_*`, `policy_*`) plus shared plumbing (`project_name`, `environment`, `location`, `owner`, `tags`), and every stage's inputs have example tfvars (`terraform.tfvars.example`, `terraform.tfvars.compute.example`, `terraform.tfvars.octopus.example`).

- **Network.** Change `vnet_address_space` and the `app`/`mgmt` subnet prefixes; tighten ingress via `mgmt_rdp_source_cidrs`, `app_http_source_prefix`, and `octopus_server_source_cidrs`; opt into plain HTTP with `app_enable_http`. Because NSG rules are keyed maps, adding a rule is a map entry, not a renumbering exercise. To attach VMs to an existing/peered network instead of the stage's own subnet, set `compute_subnet_id`. For production egress, the design already points at adding an explicit NAT Gateway (`avm-res-network-natgateway`) and setting `default_outbound_access_enabled = false` per subnet.
- **Compute.** Scale out with `compute_vm_count` (VMs are round-robined across `compute_availability_zones`); change `compute_vm_size`, `compute_vm_name_prefix` (validated to keep Windows computer names ≤ 15 chars), `compute_os_disk_storage_account_type`, and the admin identity. The VM instance map is generated from these inputs, so N VMs are a single number.
- **Image source.** Flip `image_source` between `gallery` and `jfrog`; pin a specific gallery version via `compute_image_version` (or keep `"latest"`); point the JFrog path at any Artifactory repo via `jfrog_base_url` / `jfrog_repo_path` and its staging coordinates. Both converge on the same VM code path, so no compute change is needed to switch.
- **Environments & promotion.** Rename or re-map environments via `octopus_dev/test/prod_environment_name` (the single source of truth for both creation and self-registration); change roles via `compute_octopus_target_roles` / `octopus_target_roles`; adjust the deployed package (`octopus_package_id`) and IIS site/pool/port (`octopus_iis_*`). Choose comms style per fleet (`compute_octopus_comms_style` Polling/Listening). To add human sign-off inside Octopus itself, drop an `Octopus.Manual` intervention step into the deployment process (a sketch is in `octopus.tf`); today the promotion gates live in the pipeline platform (ADO Environment approvals / GitHub required reviewers) while the Octopus lifecycle enforces the Dev → Test → Prod *sequence*.
- **Compliance.** Extend the baseline by adding required tag keys (`policy_required_tag_keys`), regions (`policy_allowed_locations`), or toggling the opt-out controls (`policy_deny_public_ip`, `policy_require_disk_encryption`); run audit-only with `policy_enforcement_mode = "DoNotEnforce"`. New built-in controls slot in as another `azurerm_resource_group_policy_assignment` following the existing pattern.
- **CI/CD portability.** Two equivalent pipelines ship (`pipelines/azure-pipelines.yml` for Azure DevOps, `pipelines/github-actions-deploy.yml` for GitHub Actions); both build/pack/push the `MSMF.GoldenImage.WebApp` package, create one release, and promote it through the environments, with server URL / space / API key supplied as pipeline secrets rather than YAML. Because the deployment process targets the `iis-web-server` **role**, new golden-image VMs are picked up automatically once they self-register — the pipeline never changes when the fleet grows.
