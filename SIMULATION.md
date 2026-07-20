# Simulated run — MOCKUP TEST (real Azure, self-cleaning)

This PoC ships with a one-command **mockup test** that runs the app against a
**real Azure subscription**, proves it provisions, and **deletes everything**
afterwards — no golden image build or VM cost required.

```bash
./scripts/simulate-run.sh        # plan (full stack) + apply network + teardown
./scripts/simulate-run.sh --plan-only   # authenticate + plan only, zero resources
# PowerShell: ./scripts/simulate-run.ps1  [-PlanOnly]
```

What it does, in order:
1. `terraform init` + `validate` + **`plan` of the full stack** — proves the code
   authenticates to Azure and the whole resource graph is valid (15 resources).
2. creates a **throwaway resource group** `rg-msmf-sim-<rand>` (tagged `ttl=temporary`).
3. `apply` of **only the network layer** — RG + VNet + `app`/`mgmt` subnets + the
   two NSGs. The golden-image / compute / Octopus stages require a pre-built
   gallery image, so they stay **plan-only** in the mockup (see README → *what
   this proves*). This keeps the test fast (~1 min) and free.
4. prints the live resources as evidence.
5. **destroys** the network layer and **deletes the resource group** on exit —
   even if a step fails (`trap`/`finally`).

## Recorded evidence (last run)

A real run was executed against subscription **Azure Local**
(`a16d84c5-…`), region `eastus`, into a throwaway RG that was deleted immediately
after:

```
=== MSMF Golden Image PoC — Stage 2a (network) SIMULATED RUN ===
Subscription: Azure Local (a16d84c5-15b4-4f50-a06c-5e5064d9345c)
Temp resource group: rg-msmf-sim-15564   (region eastus, tag ttl=temporary)
Ran (UTC-ish): {  "owner": "onluca-demo",  "purpose": "msmf-poc-simulation",  "ttl": "temporary"}

--- terraform plan (full stack, validated & authenticated) ---
Plan: 15 to add (RG + VNet + app/mgmt subnets + 2 NSGs w/ rules). azurerm auth via az CLI OK.

--- LIVE resources provisioned (az) ---
Name
-------------
msmf-vnet
msmf-app-nsg
msmf-mgmt-nsg

--- VNet + subnets ---
Subnet       Prefix        Nsg
-----------  ------------  ----------------------------------------------------------------------------------------------------------------------------------------------------
app-subnet   10.10.1.0/24  /subscriptions/a16d84c5-15b4-4f50-a06c-5e5064d9345c/resourceGroups/rg-msmf-sim-15564/providers/Microsoft.Network/networkSecurityGroups/msmf-app-nsg
mgmt-subnet  10.10.2.0/24  /subscriptions/a16d84c5-15b4-4f50-a06c-5e5064d9345c/resourceGroups/rg-msmf-sim-15564/providers/Microsoft.Network/networkSecurityGroups/msmf-mgmt-nsg

--- app NSG rules (HTTPS + Octopus Tentacle 10933) ---
Rule                    Port    Access
----------------------  ------  --------
allow_https             443     Allow
allow_octopus_tentacle  10933   Allow

--- mgmt NSG rules (RDP from mgmt CIDR) ---
Rule       Port    Src
---------  ------  ----------
allow_rdp  3389    10.0.0.0/8
```

The VNet carried both subnets, each subnet was bound to its NSG, and the app NSG
carried the **HTTPS (443)** and **Octopus Tentacle (10933)** rules while the mgmt
NSG carried **RDP (3389) restricted to the mgmt CIDR** — exactly as
`terraform/network.tf` defines. The resource group was then deleted (verified
gone). `terraform validate` passes on the full tree (Terraform 1.13, azurerm 4.x,
AVM modules pinned).
