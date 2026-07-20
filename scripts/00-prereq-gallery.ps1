#Requires -Version 5.1
<#
.SYNOPSIS
    Create the Azure Compute Gallery + image definition that Packer publishes into.

.DESCRIPTION
    Packer publishes an image *version* into an EXISTING gallery image definition;
    it does not create the gallery itself. Run this once (or let Stage-2 Terraform
    own these resources - see note below) before the first `packer build`.

    Idempotent: uses `az ... create` which is create-or-update, and checks for
    existence first so re-runs are safe. Requires the Azure CLI (`az`) logged in
    to the target subscription.

    NOTE: In the full PoC, Stage-2 Terraform can instead own the gallery via the
    AVM module `Azure/avm-res-compute-gallery/azurerm`. This script exists so
    Stage 1 is runnable stand-alone.

.EXAMPLE
    ./00-prereq-gallery.ps1 -ResourceGroup rg-msmf-gallery -GalleryName gal_msmf `
        -Location eastus -ImageDefinition win2022-iis-octopus
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $GalleryName,
    [string] $Location        = 'eastus',
    [string] $ImageDefinition = 'win2022-iis-octopus',
    [string] $Publisher       = 'globalcom',
    [string] $Offer           = 'WindowsServer-IIS-Octopus',
    [string] $Sku             = '2022-g2',
    [string] $Env             = 'dev',
    [string] $Owner           = 'platform-engineering'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-AzExists { param([string[]] $Args)
    & az @Args --output none 2>$null
    return ($LASTEXITCODE -eq 0)
}

$tags = @("project=msmf-golden-image", "env=$Env", "owner=$Owner")

Write-Host "==> Ensuring resource group '$ResourceGroup' in $Location" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --tags $tags --output none
if ($LASTEXITCODE -ne 0) { throw 'Failed to create resource group.' }

Write-Host "==> Ensuring Compute Gallery '$GalleryName'" -ForegroundColor Cyan
az sig create --resource-group $ResourceGroup --gallery-name $GalleryName `
    --location $Location --tags $tags --output none
if ($LASTEXITCODE -ne 0) { throw 'Failed to create Compute Gallery.' }

Write-Host "==> Ensuring image definition '$ImageDefinition' (Generalized, Gen2)" -ForegroundColor Cyan
$defExists = Test-AzExists @('sig', 'image-definition', 'show',
    '--resource-group', $ResourceGroup, '--gallery-name', $GalleryName,
    '--gallery-image-definition', $ImageDefinition)

if (-not $defExists) {
    az sig image-definition create `
        --resource-group $ResourceGroup `
        --gallery-name $GalleryName `
        --gallery-image-definition $ImageDefinition `
        --publisher $Publisher `
        --offer $Offer `
        --sku $Sku `
        --os-type Windows `
        --os-state Generalized `
        --hyper-v-generation V2 `
        --tags $tags `
        --output none
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create image definition.' }
    Write-Host "    Created image definition '$ImageDefinition'." -ForegroundColor Green
}
else {
    Write-Host "    Image definition '$ImageDefinition' already exists; skipping." -ForegroundColor Green
}

Write-Host ""
Write-Host "Gallery ready. Use these in windows-golden-image.pkrvars.hcl:" -ForegroundColor Green
Write-Host "  gallery_resource_group = `"$ResourceGroup`""
Write-Host "  gallery_name           = `"$GalleryName`""
Write-Host "  image_definition_name  = `"$ImageDefinition`""
