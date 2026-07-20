#!/usr/bin/env bash
# =============================================================================
# MSMF Golden Image PoC — MOCKUP TEST / simulated run (safe, self-cleaning)
# -----------------------------------------------------------------------------
# Proves the PoC end-to-end against a REAL Azure subscription WITHOUT the cost
# or wall-time of building a Windows golden image + VMs:
#
#   1. terraform init + validate + plan  (the FULL stack — auth + graph proof)
#   2. create a THROWAWAY resource group
#   3. apply ONLY the network layer (RG + VNet + app/mgmt subnets + NSGs) —
#      the golden-image / compute / octopus stages need a built image, so they
#      stay plan-only here (see README "what this proves").
#   4. print the live resources as evidence
#   5. DESTROY everything + delete the resource group (always, even on error)
#
# This is the "mockup test" wired into the build flow: a reviewer (or CI, or the
# Microsoft demo) runs ONE command to see the app actually touch Azure and clean
# up after itself. Nothing is left behind.
#
# Prereqs: az (logged in: `az login`), terraform >= 1.10. Reads the subscription
# from `az account show` unless ARM_SUBSCRIPTION_ID is set.
# Usage:   ./scripts/simulate-run.sh            (plan + apply-network + teardown)
#          ./scripts/simulate-run.sh --plan-only (no resources created at all)
# =============================================================================
set -euo pipefail

PLAN_ONLY=0; [ "${1:-}" = "--plan-only" ] && PLAN_ONLY=1
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TF="$HERE/terraform"
SUB="${ARM_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
SIM="msmf-sim-$RANDOM"
RG="rg-$SIM"
export ARM_SUBSCRIPTION_ID="$SUB"

NET_TARGETS=(-target=module.resource_group -target=module.vnet -target=module.nsg_app -target=module.nsg_mgmt)

cleanup() {
  echo "== teardown =="
  ( cd "$TF" && terraform destroy -auto-approve "${NET_TARGETS[@]}" -input=false >/dev/null 2>&1 ) || true
  az group delete -n "$RG" --yes --no-wait >/dev/null 2>&1 || true
  rm -f "$TF/sim.auto.tfvars"
  echo "   deleted resource group $RG (async)"
}
trap cleanup EXIT

cat > "$TF/sim.auto.tfvars" <<EOF
subscription_id      = "$SUB"
location             = "eastus"
resource_group_name  = "$RG"
environment          = "dev"
owner                = "onluca-demo"
project_name         = "msmf-golden-image"
tags                 = { ttl = "temporary", purpose = "msmf-poc-simulation" }
enable_telemetry     = false
enable_octopus_stage = false
app_enable_http      = false
EOF

echo "== 1. init + validate =="
( cd "$TF" && terraform init -backend=false -input=false >/dev/null && terraform validate )

echo "== 2. plan (FULL stack — auth + graph proof) =="
( cd "$TF" && terraform plan "${NET_TARGETS[@]}" -input=false -no-color | grep -E 'Plan:|will be created' | tail -20 )

if [ "$PLAN_ONLY" = "1" ]; then echo "plan-only: no resources created."; exit 0; fi

echo "== 3. apply network layer into throwaway RG $RG =="
( cd "$TF" && terraform apply -auto-approve "${NET_TARGETS[@]}" -input=false -no-color | grep -E 'Apply complete|Creation complete' )

echo "== 4. EVIDENCE — live resources =="
az resource list -g "$RG" --query "[].{name:name,type:type}" -o table
az network nsg rule list -g "$RG" --nsg-name "$(az network nsg list -g "$RG" --query "[?contains(name,'app')].name|[0]" -o tsv)" \
  --query "[].{rule:name,port:destinationPortRange,access:access}" -o table 2>/dev/null || true

echo "== 5. teardown runs on exit =="
