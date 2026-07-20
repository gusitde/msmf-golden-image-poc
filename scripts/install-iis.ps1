#Requires -Version 5.1
<#
.SYNOPSIS
    Golden-image provisioner: install and configure IIS with common web features.

.DESCRIPTION
    Stage 1 of the MS Migration Factory golden image. Installs the Web-Server role
    plus the common features required to host ASP.NET / static IIS web apps that
    Octopus Deploy will later deploy onto VMs cloned from this image.

    The script is idempotent: features already present are skipped, and the
    default site / health endpoint are (re)written each run. It is intended to run
    non-interactively inside a Packer build, but is safe to run by hand.

.NOTES
    Runs as the Packer WinRM admin user (already elevated). Exits non-zero on any
    error so the Packer build fails fast.
#>

[CmdletBinding()]
param(
    # Physical path of the default IIS site content.
    [string] $SiteRoot = 'C:\inetpub\wwwroot'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # speeds up Install-WindowsFeature

# --- Logging -----------------------------------------------------------------
$logDir = 'C:\ProgramData\msmf-golden-image\logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$transcript = Join-Path $logDir ('install-iis-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
Start-Transcript -Path $transcript -Force | Out-Null

function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }

try {
    Write-Step 'Installing IIS Web-Server role and common features'

    # Features required for hosting typical IIS + ASP.NET (4.x) web applications.
    # ASP.NET Core apps use the Web Deploy / ANCM handler shipped by the app's
    # deploy package; the base runtime hosting bundle is layered by Octopus or a
    # follow-up provisioner, keeping the OS image application-agnostic.
    $features = @(
        'Web-Server',              # IIS core
        'Web-WebServer',           # Web Server role service group
        'Web-Common-Http',         # Static content, default doc, dir browsing, http errors
        'Web-Static-Content',
        'Web-Default-Doc',
        'Web-Http-Errors',
        'Web-Http-Redirect',
        'Web-Health',              # Health & diagnostics
        'Web-Http-Logging',
        'Web-Log-Libraries',
        'Web-Request-Monitor',
        'Web-Performance',         # Static + dynamic compression
        'Web-Stat-Compression',
        'Web-Dyn-Compression',
        'Web-Security',            # Security
        'Web-Filtering',           # Request filtering
        'Web-Windows-Auth',        # Windows authentication (common for intranet apps)
        'Web-App-Dev',             # Application development
        'Web-Net-Ext45',           # .NET 4.x extensibility
        'Web-Asp-Net45',           # ASP.NET 4.x
        'Web-ISAPI-Ext',
        'Web-ISAPI-Filter',
        'Web-Mgmt-Tools',          # Management tools
        'Web-Mgmt-Console',        # IIS Manager
        'Web-Mgmt-Service',        # Remote management (WMSvc) - enables remote IIS Manager
        'Web-Scripting-Tools',     # IIS PowerShell (WebAdministration / IISAdministration)
        'NET-Framework-45-Features',
        'NET-Framework-45-Core',
        'NET-Framework-45-ASPNET'
    )

    # Determine which features are not yet installed (idempotency + faster reruns).
    $toInstall = @()
    foreach ($f in $features) {
        $state = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        if ($null -eq $state) {
            Write-Warning "Feature '$f' not found on this OS SKU; skipping."
            continue
        }
        if (-not $state.Installed) { $toInstall += $f }
    }

    if ($toInstall.Count -gt 0) {
        Write-Step ("Installing {0} feature(s): {1}" -f $toInstall.Count, ($toInstall -join ', '))
        $result = Install-WindowsFeature -Name $toInstall -IncludeManagementTools
        if (-not $result.Success) {
            throw "Install-WindowsFeature reported failure. ExitCode=$($result.ExitCode)"
        }
        if ($result.RestartNeeded -eq 'Yes') {
            # Packer performs a windows-restart after this provisioner; just note it.
            Write-Warning 'A restart is required to finish feature installation (handled by Packer).'
        }
    }
    else {
        Write-Step 'All required IIS features already installed; nothing to do.'
    }

    # --- Load the IIS administration module ---------------------------------
    Import-Module WebAdministration -ErrorAction Stop

    Write-Step 'Ensuring IIS services are enabled and started'
    foreach ($svc in @('W3SVC', 'WAS')) {
        Set-Service -Name $svc -StartupType Automatic
        if ((Get-Service $svc).Status -ne 'Running') { Start-Service $svc }
    }

    # Enable the Web Management Service (remote IIS Manager) but leave it Manual/
    # off until Stage-2 policy decides; do not open it by default for security.
    if (Get-Service -Name WMSVC -ErrorAction SilentlyContinue) {
        Set-Service -Name WMSVC -StartupType Manual
    }

    # --- Configure the default site + a health/version landing page ----------
    Write-Step 'Configuring the Default Web Site and health endpoint'

    New-Item -ItemType Directory -Path $SiteRoot -Force | Out-Null

    # Remove the stock iisstart files so our branded page is the default document.
    Get-ChildItem -Path $SiteRoot -Include 'iisstart.*' -File -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $buildStamp = (Get-Date).ToUniversalTime().ToString('u')
    $hostName   = $env:COMPUTERNAME

    $indexHtml = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MSMF Golden Image - IIS</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 3rem; color: #1b1b1f; }
    .card { max-width: 640px; padding: 1.5rem 2rem; border: 1px solid #d9d9de; border-radius: 12px; }
    h1 { margin: 0 0 .25rem; font-size: 1.4rem; }
    code { background: #f2f2f5; padding: .1rem .35rem; border-radius: 4px; }
    .ok { color: #107c10; font-weight: 600; }
  </style>
</head>
<body>
  <div class="card">
    <h1>MS Migration Factory - Golden Image</h1>
    <p class="ok">IIS is running.</p>
    <p>This host is deployed from the <code>win2022-iis-octopus</code> golden image
       and is ready to receive Octopus Deploy releases.</p>
    <p>Image baked (UTC): <code>$buildStamp</code></p>
    <p>Health probe: <code>/health.html</code></p>
  </div>
</body>
</html>
"@
    Set-Content -Path (Join-Path $SiteRoot 'index.html') -Value $indexHtml -Encoding UTF8 -Force

    # A tiny static health file usable by Azure Load Balancer / App Gateway probes
    # and by Octopus deployment health checks.
    Set-Content -Path (Join-Path $SiteRoot 'health.html') -Value 'OK' -Encoding ASCII -Force

    # Make index.html the top default document so the branded page wins.
    # Guard against the "duplicate collection entry" error so re-runs are safe.
    $defaultDocFilter = 'system.webServer/defaultDocument/files'
    try {
        $currentDocs = @((Get-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site' -Filter $defaultDocFilter -Name Collection).Value)
    }
    catch { $currentDocs = @() }
    if ($currentDocs -notcontains 'index.html') {
        try {
            Add-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site' -Filter $defaultDocFilter `
                -Name '.' -AtIndex 0 -Value @{ value = 'index.html' }
        }
        catch {
            if ($_.Exception.Message -notmatch 'duplicate') { throw }
        }
    }

    # Ensure the Default Web Site + its app pool are started.
    if ((Get-WebAppPoolState -Name 'DefaultAppPool').Value -ne 'Started') {
        Start-WebAppPool -Name 'DefaultAppPool'
    }
    if ((Get-WebsiteState -Name 'Default Web Site').Value -ne 'Started') {
        Start-Website -Name 'Default Web Site'
    }

    # Open HTTP (80) in the Windows firewall for the default site. Stage-2 NSGs
    # remain the authoritative network control; this simply makes the baked image
    # self-serve for smoke tests.
    if (-not (Get-NetFirewallRule -DisplayName 'MSMF-IIS-HTTP-In' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'MSMF-IIS-HTTP-In' -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort 80 -Profile Any | Out-Null
    }

    # --- Local smoke test ----------------------------------------------------
    Write-Step 'Smoke-testing the local IIS endpoint'
    try {
        $resp = Invoke-WebRequest -Uri 'http://localhost/health.html' -UseBasicParsing -TimeoutSec 30
        if ($resp.StatusCode -ne 200 -or $resp.Content.Trim() -ne 'OK') {
            throw "Unexpected health response: HTTP $($resp.StatusCode) '$($resp.Content)'"
        }
        Write-Host "Health check OK (HTTP $($resp.StatusCode))." -ForegroundColor Green
    }
    catch {
        throw "IIS local smoke test failed: $($_.Exception.Message)"
    }

    # --- Build marker for traceability inside the image ----------------------
    $markerDir = 'C:\ProgramData\msmf-golden-image'
    $marker = [pscustomobject]@{
        component     = 'iis'
        installedUtc  = $buildStamp
        host          = $hostName
        features      = ($features -join ',')
    } | ConvertTo-Json -Depth 3
    Set-Content -Path (Join-Path $markerDir 'iis.marker.json') -Value $marker -Encoding UTF8 -Force

    Write-Step 'IIS provisioning complete.'
}
catch {
    Write-Error "install-iis.ps1 FAILED: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
