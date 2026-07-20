<#
  MSMF Golden Image PoC - MOCKUP TEST / simulated run (safe, self-cleaning).

  Same as scripts/simulate-run.sh, for Windows/PowerShell reviewers.
  1. terraform init + validate + plan (full stack - auth + graph proof)
  2. create a throwaway resource group
  3. apply ONLY the network layer (RG + VNet + subnets + NSGs)
  4. print live resources as evidence
  5. destroy + delete the RG (always, even on error)

  Prereqs: az (logged in), terraform >= 1.10.
  Usage:   ./scripts/simulate-run.ps1            (plan + apply-network + teardown)
           ./scripts/simulate-run.ps1 -PlanOnly  (no resources created)
#>
param([switch]$PlanOnly)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSScriptRoot
$tf   = Join-Path $here 'terraform'
$sub  = if ($env:ARM_SUBSCRIPTION_ID) { $env:ARM_SUBSCRIPTION_ID } else { az account show --query id -o tsv }
$rg   = "rg-msmf-sim-$(Get-Random -Maximum 99999)"
$env:ARM_SUBSCRIPTION_ID = $sub
$targets = @('-target=module.resource_group','-target=module.vnet','-target=module.nsg_app','-target=module.nsg_mgmt')

$tfvars = @"
subscription_id      = "$sub"
location             = "eastus"
resource_group_name  = "$rg"
environment          = "dev"
owner                = "onluca-demo"
project_name         = "msmf-golden-image"
tags                 = { ttl = "temporary", purpose = "msmf-poc-simulation" }
enable_telemetry     = false
enable_octopus_stage = false
app_enable_http      = false
"@
Set-Content -Path (Join-Path $tf 'sim.auto.tfvars') -Value $tfvars -Encoding utf8

try {
  Write-Host '== 1. init + validate =='
  Push-Location $tf
  terraform init -backend=false -input=false | Out-Null
  terraform validate

  Write-Host '== 2. plan (full stack - auth + graph proof) =='
  terraform plan @targets -input=false -no-color | Select-String 'Plan:|will be created'

  if (-not $PlanOnly) {
    Write-Host "== 3. apply network layer into throwaway RG $rg =="
    terraform apply -auto-approve @targets -input=false -no-color | Select-String 'Apply complete|Creation complete'

    Write-Host '== 4. EVIDENCE - live resources =='
    az resource list -g $rg --query "[].{name:name,type:type}" -o table
  }
  Pop-Location
}
finally {
  Write-Host '== 5. teardown =='
  Push-Location $tf
  terraform destroy -auto-approve @targets -input=false 2>$null | Out-Null
  Pop-Location
  az group delete -n $rg --yes --no-wait 2>$null | Out-Null
  Remove-Item (Join-Path $tf 'sim.auto.tfvars') -ErrorAction SilentlyContinue
  Write-Host "   deleted resource group $rg (async)"
}
