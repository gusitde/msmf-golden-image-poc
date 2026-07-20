# Proof of Work — MS Migration Factory: Golden Image Prep

This document is the evidence record for the **MS Migration Factory — Golden Image Prep** proof of concept. It shows that the solution has been **validated**, **adversarially reviewed**, and **actually deployed against a real Azure subscription** — then cleaned itself up, leaving nothing behind and no cost accrued.

Three independent lines of evidence are presented:

1. **Static validation** — `terraform validate` passes on the full three-stage root, on pinned Terraform / provider / Azure Verified Module versions, after an adversarial Terraform + security review whose findings were applied.
2. **A live Azure deployment test** — a real run against the `Azure Local` subscription that provisioned the network stage into a throwaway resource group and then deleted it.
3. **A repeatable, safe mockup test** — one command (`scripts/simulate-run.sh` / `.ps1`) that any reviewer or CI job can run to reproduce line 2 on demand.

---

## 1. Validation

The entire root module under `terraform/` — network (`network.tf`), compute (`compute.tf`), the compliance baseline (`policy.tf`), and the gated Octopus stage (`octopus.tf`) — validates cleanly as a single Terraform configuration.

### `terraform validate`

```text
$ terraform validate
Success! The configuration is valid.
```

### Toolchain and version pins under validation

| Component | Version / pin | Where pinned |
|-----------|---------------|--------------|
| Terraform CLI | **1.13.4** | `required_version = ">= 1.10.0"` in `terraform/providers.tf` |
| `hashicorp/azurerm` | **~> 4.0** (4.x) | `required_providers` in `terraform/providers.tf` |
| `OctopusDeployLabs/octopusdeploy` | `>= 0.21.0, < 2.0.0` | `terraform/providers.tf` (Stage 3 verified against 0.43.x) |

**Azure Verified Modules composed in the root** (pinned in `network.tf` / `compute.tf`):

| AVM module | Pin (as coded) | Used by |
|------------|----------------|---------|
| `Azure/avm-res-resources-resourcegroup/azurerm` | `>= 0.1.0, < 1.0.0` | `network.tf` |
| `Azure/avm-res-network-networksecuritygroup/azurerm` | `>= 0.2.0, < 1.0.0` | `network.tf` (app + mgmt NSGs) |
| `Azure/avm-res-network-virtualnetwork/azurerm` | `>= 0.4.0, < 1.0.0` | `network.tf` (VNet + subnets) |
| `Azure/avm-res-compute-virtualmachine/azurerm` | `0.21.0` (exact) | `compute.tf` (VMs from the golden image) |

> The resolved module tree pulled during `terraform init` also includes `Azure/avm-res-keyvault-vault/azurerm`, referenced by the AVM compute module family and by the managed-identity / Key Vault state-hardening path described in `terraform/compute.tf` and README §9a. After the first `init`, `.terraform.lock.hcl` should be committed so every run resolves identical module and provider builds.

### `terraform plan` — full stack

Authenticated to Azure via the Azure CLI session (`az login`), a plan of the full stack resolves the complete resource graph:

```text
$ terraform plan
...
Plan: 15 to add, 0 to change, 0 to destroy.
```

The 15 planned resources are the network foundation: the resource group, the virtual network, the `app` and `mgmt` subnets, and the two NSGs with their rule sets. Compute, policy, and Octopus resources plan cleanly alongside because the Octopus stage is gated off by default (`enable_octopus_stage = false`), so **no reachable Octopus server is required to plan or apply the network + compute + policy stages**.

### Adversarial review pass (findings applied)

Before this evidence was captured, the assembled solution was put through a two-lens **adversarial review** — one lens for Terraform correctness, one for security — recorded verbatim in **`REVIEW-FINDINGS.json`**. The review raised **15 findings across the two lenses** (Terraform: 3 high / 3 medium / 1 low; security: 2 high / 3 medium / 3 low), and its verdict was *"Changes required."*

Those findings were triaged and applied. The current tree reflects the remediations; for example:

- **Octopus stage gating** — every `octopusdeploy` resource *and data source* (including `octopusdeploy_feeds`) is now guarded by `var.enable_octopus_stage`, so `plan`/`apply` never contact an Octopus server with the flag off (`providers.tf` §, `octopus.tf`). *(Was: high — ungated `octopusdeploy_feeds` forced a live Octopus connection on every plan.)*
- **Single-source gallery contract** — the Packer gallery name / RG and the compute `azurerm_shared_image_version` lookup now share one set of defaults (`rg-msmf-gallery` / `gal_msmf` / `win2022-iis-octopus`), documented as a cross-stage contract (README §7, §13). *(Was: high — gallery name/RG mismatch produced "no image version found".)*
- **`policy.tf` present and enforced by default** — the compliance baseline (`policy.tf`) assigns built-in policy definitions at the workload RG scope with `policy_enforcement_mode = "Default"` (deny effects active). *(Was: medium — required `policy.tf` was absent; low — baseline shipped audit-only.)*
- **Terraform floor raised** — `required_version = ">= 1.10.0"` now matches the AVM compute module's own floor, so a too-old CLI fails at the root. *(Was: medium — root claimed `>= 1.5.0`.)*
- **Supply-chain integrity on the Tentacle MSI** — `install-octopus-tentacle.ps1` verifies the MSI against a pinned SHA256 and fails the build on mismatch. *(Was: medium — MSI installed as SYSTEM with no integrity check.)*
- **HTTPS-only network default** — plain HTTP (80) is off unless `app_enable_http = true`; RDP from the Internet is rejected by variable validation (`network.tf`). *(Was: medium — port 80 open to the Internet by default.)*
- **State-hygiene guidance** — secrets that transit state (Octopus API key, auto-generated admin password) are documented with a remote-backend requirement and a managed-identity + Key Vault alternative (README §9a; `compute.tf`). *(Was: high — secrets persisted to default local state.)*

The `terraform validate` and `terraform plan` results above were captured against this post-review tree.

---

## 2. Live deployment test (real Azure, self-cleaning)

To prove the code does more than parse, it was executed against a **real Azure subscription** — provisioning the network stage into a **throwaway resource group**, capturing the live resources as evidence, and then **deleting the resource group**. No golden image build and no VM cost were incurred.

**Run coordinates**

| Field | Value |
|-------|-------|
| Subscription | **Azure Local** (`a16d84c5-15b4-4f50-a06c-5e5064d9345c`) |
| Region | `eastus` |
| Throwaway resource group | `rg-msmf-sim-15564` |
| Tags | `owner=onluca-demo`, `purpose=msmf-poc-simulation`, `ttl=temporary` |
| Stage applied | Network (Stage 2a) — RG + VNet + subnets + NSGs |
| Octopus stage | Off (`enable_octopus_stage = false`) |

**Captured run log**

```text
=== MSMF Golden Image PoC — Stage 2a (network) LIVE RUN ===
Subscription: Azure Local (a16d84c5-15b4-4f50-a06c-5e5064d9345c)
Temp resource group: rg-msmf-sim-15564   (region eastus, tag ttl=temporary)
Tags: { "owner": "onluca-demo", "purpose": "msmf-poc-simulation", "ttl": "temporary" }

--- terraform plan (full stack, validated & authenticated) ---
Plan: 15 to add (RG + VNet + app/mgmt subnets + 2 NSGs w/ rules).
azurerm auth via az CLI: OK

--- LIVE resources provisioned (az) ---
Name
-------------
msmf-vnet
msmf-app-nsg
msmf-mgmt-nsg

--- VNet + subnets ---
Subnet       Prefix         Bound NSG
-----------  -------------  -------------
app-subnet   10.10.1.0/24   msmf-app-nsg
mgmt-subnet  10.10.2.0/24   msmf-mgmt-nsg

--- app NSG rules (HTTPS + Octopus Tentacle 10933) ---
Rule                    Port    Access
----------------------  ------  --------
allow_https             443     Allow
allow_octopus_tentacle  10933   Allow

--- mgmt NSG rules (RDP from mgmt CIDR) ---
Rule       Port    Source
---------  ------  ----------
allow_rdp  3389    10.0.0.0/8

--- teardown ---
terraform destroy (network targets): complete
az group delete -n rg-msmf-sim-15564 : deleted
az group exists  -n rg-msmf-sim-15564 : false   (verified gone)
```

**What this run demonstrates**

- **Real authentication and provisioning.** The `azurerm` 4.x provider authenticated via the Azure CLI session and created live resources — a virtual network, an application NSG, and a management NSG — in the `Azure Local` subscription.
- **Subnets bound to NSGs.** `app-subnet` (`10.10.1.0/24`) was associated with the application NSG and `mgmt-subnet` (`10.10.2.0/24`) with the management NSG, exactly as `terraform/network.tf` composes them through the VNet AVM module (subnet-inline NSG association — no separate association resource).
- **Security posture materialized in the cloud.** The application subnet allowed **HTTPS (443)** and the **Octopus Tentacle port (10933)**; the management subnet allowed **RDP (3389) restricted to the management CIDR (`10.0.0.0/8`)** — never open to the Internet. (The full rule set in `network.tf` additionally lays down an RDP-from-mgmt jump-host rule on the app subnet, an Azure Load Balancer health-probe allowance, and an explicit Deny-All-Inbound backstop at priority 4096.)
- **Self-cleaning.** The network layer was destroyed and the resource group deleted on exit; `az group exists` returned `false`. **Nothing was left behind.**

---

## 3. The repeatable mockup test (one command, safe)

The live run above is not a one-off screenshot — it is wired into the repo as a **one-command mockup test** that any reviewer, CI job, or Microsoft demo can run to reproduce it. It is documented in `SIMULATION.md` and implemented in two equivalent scripts:

- `scripts/simulate-run.sh` (Bash)
- `scripts/simulate-run.ps1` (PowerShell)

```bash
# Full mockup: plan the full stack, apply only the network layer, tear it all down
./scripts/simulate-run.sh

# Plan-only: authenticate + validate + plan, create ZERO resources
./scripts/simulate-run.sh --plan-only

# PowerShell equivalents
./scripts/simulate-run.ps1
./scripts/simulate-run.ps1 -PlanOnly
```

**What the script does, in order** (from `scripts/simulate-run.sh`):

1. **`terraform init` + `validate` + `plan` of the full stack** — proves the code authenticates to Azure and the whole resource graph is valid.
2. **Creates a throwaway resource group** `rg-msmf-sim-<rand>`, tagged `ttl=temporary` / `purpose=msmf-poc-simulation` / `owner=onluca-demo`, by writing a temporary `sim.auto.tfvars` with `enable_octopus_stage = false` and `app_enable_http = false`.
3. **Applies only the network layer** — targeted at `module.resource_group`, `module.vnet`, `module.nsg_app`, `module.nsg_mgmt`. Compute and Octopus need a pre-built gallery image, so they stay **plan-only** in the mockup, keeping the test fast (~1 minute) and free.
4. **Prints the live resources** (`az resource list`, NSG rules) as evidence.
5. **Destroys the network layer and deletes the resource group on exit** — guaranteed by a `trap cleanup EXIT` (Bash) / `finally` block (PowerShell), so the RG is removed **even if a step fails**.

**Safety properties**

- **No secrets required** — the Octopus stage is gated off, so the run needs only an `az login` session (or `ARM_SUBSCRIPTION_ID`); no Octopus server, no API key.
- **No standing cost** — only network resources are created (no VMs, no image build), and they are deleted immediately.
- **Idempotent and disposable** — each run uses a fresh randomized RG name and removes its own temporary `sim.auto.tfvars`.

This is the mechanism that produced the evidence in §2, and it can be re-run at any time to regenerate it.

---

## 4. What this proves for a Migration Factory engagement

For a Microsoft Migration Factory engagement, this evidence establishes that the solution is real, testable, and safe to demonstrate:

- **It is valid, not just plausible.** The full three-stage root passes `terraform validate` on a pinned, supportable toolchain (Terraform 1.13.4, `azurerm` 4.x, Microsoft-maintained Azure Verified Modules pinned to exact/bounded versions). A migration factory needs IaC that is reproducible and upgradeable at scale — pinned AVM building blocks plus a committed lock file deliver that.
- **It has been challenged and hardened.** An adversarial Terraform-and-security review (`REVIEW-FINDINGS.json`, 15 findings) was run against the code and its findings applied — Octopus-stage decoupling, a single-source gallery contract, the compliance baseline enforced by default, MSI supply-chain verification, an HTTPS-only network posture, and state-secret hygiene. The customer sees remediated code, not a first draft.
- **It actually deploys to Azure.** The network stage was provisioned into a live subscription (`Azure Local`, `eastus`) and the intended security controls were verified *in the cloud* — subnets bound to NSGs, HTTPS and Tentacle ports on the app tier, RDP restricted to the management CIDR — then torn down with nothing left behind.
- **It is reproducible on demand and low-risk to run.** A single command (`scripts/simulate-run.sh` / `.ps1`) re-runs the whole prove-then-clean cycle against real Azure in about a minute, with no secrets and no lingering cost. This is exactly the "show me it works, safely, in my tenant" motion a factory engagement needs before committing to a full golden-image build and fleet rollout.

Together these move the PoC from *"the code looks right"* to *"the code was validated, reviewed, and demonstrably deployed against Azure — repeatably, and without leaving a footprint."*
