#Requires -Version 5.1
<#
.SYNOPSIS
    Registers a golden-image baked-in Octopus Deploy Tentacle with an Octopus
    Server, into a specific Space, Environment and Role set.

.DESCRIPTION
    MS Migration Factory — Golden Image Prep, Stage 2b (compute).

    The golden image (built by Stage 1 with Packer) already has the Octopus
    Tentacle installed but NOT registered — the image is generalized, so every
    VM cloned from it must obtain a UNIQUE certificate/thumbprint and register
    itself on first boot. This script is invoked by the Azure CustomScript VM
    extension (see terraform/compute.tf) and is fully idempotent: re-runs are
    safe and short-circuit once a registration marker is present (unless -Force).

    Comms styles:
      * Polling   (TentacleActive)  — Tentacle dials the server on :10943.
                                       Cloud-friendly, needs no inbound ports.
      * Listening (TentaclePassive) — Server dials the Tentacle on :10933.
                                       Requires reachability (public IP / peering)
                                       and the server thumbprint to trust.

.NOTES
    The API key is supplied at runtime via -ApiKey (from the extension's
    protected settings) and is masked in logs; it is never written to disk.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OctopusServerUrl,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Environment,             # comma-separated allowed
    [Parameter(Mandatory = $true)][string]$Roles,                   # comma-separated
    [string]$Space = "Default",
    [ValidateSet("Listening", "Polling")][string]$CommsStyle = "Polling",
    [int]$ListenPort = 10933,
    [int]$ServerCommsPort = 10943,
    [string]$InstanceName = "Tentacle",
    [string]$ApplicationsDirectory = "C:\Octopus\Applications",
    [string]$MachineName = $env:COMPUTERNAME,
    [string]$ServerThumbprint = "",
    [string]$MachinePolicy = "Default Machine Policy",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:ProgramData 'msmf-bootstrap'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
try { Start-Transcript -Path (Join-Path $logDir 'register-octopus-tentacle.log') -Append | Out-Null } catch {}

function Write-Log { param([string]$Message) Write-Host ("[{0}] {1}" -f (Get-Date -Format o), $Message) }

try {
    Write-Log "Starting Octopus Tentacle registration for machine '$MachineName' (comms=$CommsStyle)."

    # ------------------------------------------------------------------ #
    # 1) Locate Tentacle.exe (baked into the golden image by Stage 1).
    # ------------------------------------------------------------------ #
    $pf   = $env:ProgramFiles
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')

    $candidates = @()
    if ($pf)   { $candidates += (Join-Path $pf   'Octopus Deploy\Tentacle\Tentacle.exe') }
    if ($pf86) { $candidates += (Join-Path $pf86 'Octopus Deploy\Tentacle\Tentacle.exe') }

    $tentacle = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $tentacle) {
        # Fallback: search the Program Files roots only (fast, not a full C:\ crawl).
        $roots = @($pf, $pf86, 'C:\Octopus') | Where-Object { $_ -and (Test-Path $_) }
        foreach ($root in $roots) {
            $hit = Get-ChildItem -Path $root -Recurse -Filter 'Tentacle.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $tentacle = $hit.FullName; break }
        }
    }
    if (-not $tentacle) { throw "Tentacle.exe not found. The golden image must have the Octopus Tentacle installed (Stage 1)." }
    Write-Log "Using Tentacle: $tentacle"

    function Invoke-Tentacle {
        param([Parameter(Mandatory)][string[]]$TentacleArgs, [switch]$AllowFail)
        $masked = ($TentacleArgs | ForEach-Object { if ($_ -eq $ApiKey) { '***' } else { $_ } }) -join ' '
        Write-Log "tentacle $masked"
        & $tentacle @TentacleArgs
        if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
            throw "Tentacle command '$($TentacleArgs[0])' failed with exit code $LASTEXITCODE."
        }
    }

    # ------------------------------------------------------------------ #
    # 2) Idempotency guard.
    # ------------------------------------------------------------------ #
    $marker = Join-Path $logDir "registered-$InstanceName.marker"
    if ((Test-Path $marker) -and -not $Force) {
        Write-Log "Registration marker present ($marker). Already registered; use -Force to re-register. Done."
        return
    }

    # ------------------------------------------------------------------ #
    # 3) Ensure a Tentacle instance with a UNIQUE certificate.
    # ------------------------------------------------------------------ #
    $instanceRoot = Join-Path $env:ProgramData "Octopus\Tentacle\$InstanceName"
    $configPath = Join-Path $instanceRoot 'Tentacle.config'
    New-Item -ItemType Directory -Force -Path $instanceRoot | Out-Null

    if (-not (Test-Path $configPath)) {
        Invoke-Tentacle @('create-instance', '--instance', $InstanceName, '--config', $configPath)
    }
    else {
        Write-Log "Instance config already present at $configPath."
    }

    # Generate a fresh certificate only if none exists (unique per VM).
    Invoke-Tentacle @('new-certificate', '--instance', $InstanceName, '--if-blank')

    # ------------------------------------------------------------------ #
    # 4) Base + comms-style configuration.
    # ------------------------------------------------------------------ #
    Invoke-Tentacle @('configure', '--instance', $InstanceName, '--home', 'C:\Octopus', '--app', $ApplicationsDirectory)
    Invoke-Tentacle @('configure', '--instance', $InstanceName, '--reset-trust')

    if ($CommsStyle -eq 'Listening') {
        Invoke-Tentacle @('configure', '--instance', $InstanceName, '--port', "$ListenPort", '--noListen', 'False')
        if ($ServerThumbprint) {
            Invoke-Tentacle @('configure', '--instance', $InstanceName, '--trust', $ServerThumbprint)
        }
        else {
            Write-Log "WARNING: Listening mode without -ServerThumbprint; the Tentacle will not trust the server until a thumbprint is configured."
        }
        try {
            New-NetFirewallRule -DisplayName "Octopus Tentacle ($ListenPort)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ListenPort -ErrorAction Stop | Out-Null
            Write-Log "Opened inbound firewall port $ListenPort."
        }
        catch { Write-Log "Firewall rule not added (may already exist): $($_.Exception.Message)" }
    }
    else {
        Invoke-Tentacle @('configure', '--instance', $InstanceName, '--noListen', 'True')
    }

    # ------------------------------------------------------------------ #
    # 5) Install + start the Windows service for this instance.
    # ------------------------------------------------------------------ #
    Invoke-Tentacle @('service', '--instance', $InstanceName, '--install', '--start', '--reconfigure') -AllowFail

    # ------------------------------------------------------------------ #
    # 6) Resolve host address via Azure IMDS (Listening publicHostName).
    # ------------------------------------------------------------------ #
    $publicHost = $null
    try {
        $meta = Invoke-RestMethod -Headers @{ Metadata = 'true' } -TimeoutSec 10 `
            -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-12-13'
        $ipv4 = $meta.network.interface[0].ipv4.ipAddress[0]
        $publicHost = if ($ipv4.publicIpAddress) { $ipv4.publicIpAddress } else { $ipv4.privateIpAddress }
        Write-Log "IMDS host address: $publicHost"
    }
    catch { Write-Log "IMDS lookup failed (continuing): $($_.Exception.Message)" }

    # ------------------------------------------------------------------ #
    # 7) Register with the Octopus Server.
    # ------------------------------------------------------------------ #
    $reg = @(
        'register-with',
        '--instance', $InstanceName,
        '--server', $OctopusServerUrl,
        '--apiKey', $ApiKey,
        '--space', $Space,
        '--name', $MachineName,
        '--policy', $MachinePolicy,
        '--force'
    )
    foreach ($e in ($Environment -split ',')) { $t = $e.Trim(); if ($t) { $reg += @('--environment', $t) } }
    foreach ($r in ($Roles -split ',')) { $t = $r.Trim(); if ($t) { $reg += @('--role', $t) } }

    if ($CommsStyle -eq 'Listening') {
        $reg += @('--comms-style', 'TentaclePassive', '--tentacle-comms-port', "$ListenPort")
        if ($publicHost) { $reg += @('--publicHostName', $publicHost) }
    }
    else {
        $reg += @('--comms-style', 'TentacleActive', '--server-comms-port', "$ServerCommsPort")
    }

    Invoke-Tentacle $reg

    Set-Content -Path $marker -Value (Get-Date -Format o)
    Write-Log "SUCCESS: '$MachineName' registered into Space '$Space', Environment(s) '$Environment', Role(s) '$Roles'."
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace }
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
