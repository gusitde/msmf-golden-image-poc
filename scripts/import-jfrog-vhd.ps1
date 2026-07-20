#Requires -Version 5.1
<#
.SYNOPSIS
    Imports a golden-image VHD from JFrog Artifactory into an Azure storage
    account as a page blob, ready to be wrapped as a managed image.

.DESCRIPTION
    MS Migration Factory — Golden Image Prep, Stage 2b (compute), JFrog path.

    Terraform cannot natively stream a large VHD out of Artifactory, so this
    helper is invoked by `terraform_data.jfrog_vhd_import` (local-exec) when
    var.image_source = "jfrog". It:
      1. ensures the staging container exists,
      2. skips work if the destination blob already exists (idempotent),
      3. stream-downloads the VHD from Artifactory (Bearer token preferred,
         else basic auth),
      4. uploads it as a PAGE blob (required for managed-image creation).

    terraform/compute.tf then builds `azurerm_image.jfrog` from the resulting
    blob URI, and the VMs boot from that managed image.

    Credentials are read from environment variables set by Terraform
    (JFROG_ACCESS_TOKEN | JFROG_USERNAME/JFROG_PASSWORD) — never passed on the
    command line or persisted in state — and are handed to curl as a config
    document on STDIN (`--config -`), so they never appear in ANY process's
    argv (curl's included) during the long-running download.

.REQUIREMENTS
    PowerShell 7 (pwsh), Azure CLI (`az`) logged in with rights to the storage
    account, and native `curl` on PATH.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceUrl,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$StorageAccount,
    [Parameter(Mandatory = $true)][string]$Container,
    [Parameter(Mandatory = $true)][string]$BlobName,
    [ValidateSet("login", "key")][string]$AuthMode = "login",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
function Write-Log { param([string]$Message) Write-Host ("[{0}] {1}" -f (Get-Date -Format o), $Message) }

$jfUser  = $env:JFROG_USERNAME
$jfPass  = $env:JFROG_PASSWORD
$jfToken = $env:JFROG_ACCESS_TOKEN

# ---------------------------------------------------------------------------#
# 0) Preconditions — resolve the native executables (avoid PS aliases).
# ---------------------------------------------------------------------------#
$azBin = (Get-Command -Name az -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $azBin) { throw "Azure CLI ('az') was not found on PATH." }
$curlBin = (Get-Command -Name curl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $curlBin) { throw "The native 'curl' executable was not found on PATH." }

$azCommon = @('--auth-mode', $AuthMode, '--only-show-errors')

# ---------------------------------------------------------------------------#
# 1) Ensure the staging container exists.
# ---------------------------------------------------------------------------#
Write-Log "Ensuring container '$Container' exists in storage account '$StorageAccount' (rg '$ResourceGroup')."
& az storage container create --name $Container --account-name $StorageAccount @azCommon | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to ensure container '$Container'." }

# ---------------------------------------------------------------------------#
# 2) Idempotency — skip if the blob already exists (unless -Force).
# ---------------------------------------------------------------------------#
$exists = & az storage blob exists --account-name $StorageAccount --container-name $Container --name $BlobName @azCommon --query exists -o tsv
if ($exists -eq 'true' -and -not $Force) {
    Write-Log "Blob '$BlobName' already exists in '$StorageAccount/$Container'; skipping import (use -Force to re-import)."
    exit 0
}

# ---------------------------------------------------------------------------#
# 3) Stream-download the VHD from Artifactory.
# ---------------------------------------------------------------------------#
$tmp = Join-Path ([IO.Path]::GetTempPath()) $BlobName
if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Write-Log "Downloading VHD from Artifactory: $SourceUrl"

# ---------------------------------------------------------------------------#
# Credentials are fed to curl via a config document on STDIN (`--config -`),
# NEVER as command-line arguments: argv of a running process is readable by
# any other process on the CI runner (Win32_Process.CommandLine / /proc), and
# this download runs for minutes on a large VHD. Stdin is private to curl.
# ---------------------------------------------------------------------------#

# curl config quoted-string escaping: backslash and double-quote must be escaped.
function ConvertTo-CurlConfigString {
    param([string]$Value)
    return '"' + (($Value -replace '\\', '\\') -replace '"', '\"') + '"'
}

if ($jfToken) {
    $curlConfig = 'header = ' + (ConvertTo-CurlConfigString "Authorization: Bearer $jfToken")
}
elseif ($jfUser -and $jfPass) {
    $curlConfig = 'user = ' + (ConvertTo-CurlConfigString "${jfUser}:${jfPass}")
}
else {
    throw "No Artifactory credentials supplied. Set JFROG_ACCESS_TOKEN or JFROG_USERNAME/JFROG_PASSWORD."
}

$curlArgs = @('--config', '-', '--fail', '--location', '--silent', '--show-error', '--retry', '5', '--retry-delay', '10', '--output', $tmp)
$curlArgs += $SourceUrl

$curlConfig | & $curlBin @curlArgs
$curlConfig = $null
if ($LASTEXITCODE -ne 0) { throw "Download from Artifactory failed (curl exit $LASTEXITCODE)." }
if (-not (Test-Path $tmp)) { throw "Download reported success but '$tmp' is missing." }
$sizeGb = [math]::Round((Get-Item $tmp).Length / 1GB, 2)
Write-Log "Downloaded $sizeGb GB to $tmp."

# ---------------------------------------------------------------------------#
# 4) Upload as a PAGE blob (required so it can back a managed image).
# ---------------------------------------------------------------------------#
Write-Log "Uploading page blob to $StorageAccount/$Container/$BlobName ..."
& az storage blob upload `
    --account-name $StorageAccount `
    --container-name $Container `
    --name $BlobName `
    --file $tmp `
    --type page `
    --overwrite true `
    @azCommon | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Upload to storage account failed (az exit $LASTEXITCODE)." }

# ---------------------------------------------------------------------------#
# 5) Cleanup.
# ---------------------------------------------------------------------------#
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
Write-Log "JFrog VHD import complete: https://$StorageAccount.blob.core.windows.net/$Container/$BlobName"
