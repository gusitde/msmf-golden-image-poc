#Requires -Version 5.1
<#
.SYNOPSIS
    Install, configure and (optionally) register an Octopus Deploy Tentacle.

.DESCRIPTION
    Stage 1 of the MS Migration Factory golden image. Two ways this script is used:

      1. GOLDEN IMAGE BUILD (Packer, default): install the Tentacle MSI and stage
         this script into the image. It does NOT create the Tentacle instance,
         certificate or register with the server. This is deliberate: a generalized
         image is cloned to many VMs, so baking a certificate/registration would
         make every clone share one identity and collide in Octopus.
         -> Achieved by leaving -RegisterWithServer $false (env
            OCTOPUS_REGISTER_DURING_BUILD=false).

      2. FIRST BOOT (Stage-2 custom-script extension / cloud-init) or a single-VM
         demo: fully create the instance + a UNIQUE certificate, configure the
         Listening/Polling comms style, install the Windows service and register
         the machine with Octopus (roles + environment).
         -> Achieved with -RegisterWithServer:$true.

    Idempotent: the MSI install, instance/certificate creation, service install
    and registration (register-with --force) can all be re-run safely.

.PARAMETER RegisterWithServer
    When $true, creates the instance/certificate and registers with Octopus.
    When $false (default for the image build), installs the MSI + stages the
    script only.

.NOTES
    Parameters default from environment variables so the same script works as a
    Packer provisioner (env vars) and as an Azure custom-script extension
    (named arguments). Exits non-zero on failure.
#>

[CmdletBinding()]
param(
    [bool]     $RegisterWithServer  = ($env:OCTOPUS_REGISTER_DURING_BUILD -eq 'true'),
    [string]   $InstanceName        = $(if ($env:OCTOPUS_INSTANCE_NAME) { $env:OCTOPUS_INSTANCE_NAME } else { 'Tentacle' }),
    [string]   $ServerUrl           = $env:OCTOPUS_SERVER_URL,
    [string]   $ApiKey              = $env:OCTOPUS_API_KEY,
    [string]   $Space               = $(if ($env:OCTOPUS_SPACE) { $env:OCTOPUS_SPACE } else { 'Default' }),
    [string[]] $Environments        = @(),
    [string[]] $Roles               = @(),
    [ValidateSet('Listen', 'Poll')]
    [string]   $CommunicationMode   = $(if ($env:OCTOPUS_COMMS_STYLE) { $env:OCTOPUS_COMMS_STYLE } else { 'Poll' }),
    [int]      $ListenPort          = $(if ($env:OCTOPUS_LISTEN_PORT) { [int]$env:OCTOPUS_LISTEN_PORT } else { 10933 }),
    [int]      $ServerCommsPort     = $(if ($env:OCTOPUS_SERVER_COMMS_PORT) { [int]$env:OCTOPUS_SERVER_COMMS_PORT } else { 10943 }),
    [string]   $ServerThumbprint    = $env:OCTOPUS_SERVER_THUMBPRINT,
    [string]   $PublicHostName      = $env:OCTOPUS_PUBLIC_HOSTNAME,
    [string]   $MachineName         = $(if ($env:OCTOPUS_MACHINE_NAME) { $env:OCTOPUS_MACHINE_NAME } else { $env:COMPUTERNAME }),
    [string]   $TentacleDownloadUrl = $(if ($env:OCTOPUS_TENTACLE_DOWNLOAD_URL) { $env:OCTOPUS_TENTACLE_DOWNLOAD_URL } else { 'https://octopus.com/downloads/latest/WindowsX64/OctopusTentacle' }),
    # Expected SHA256 of the Tentacle MSI. STRONGLY recommended: pin
    # $TentacleDownloadUrl to a specific version and set this hash so a
    # compromised/redirected download can never be installed as SYSTEM and
    # baked into every clone. Empty = skip verification with a loud warning.
    [string]   $TentacleMsiSha256   = $env:OCTOPUS_TENTACLE_MSI_SHA256,
    [string]   $OctopusHome         = 'C:\Octopus',
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Populate list params from comma-separated env vars when not passed explicitly.
if (-not $Environments -or $Environments.Count -eq 0) {
    $Environments = @(($env:OCTOPUS_ENVIRONMENT -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $Roles -or $Roles.Count -eq 0) {
    $Roles = @(($env:OCTOPUS_ROLES -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# --- Logging -----------------------------------------------------------------
$stateDir = 'C:\ProgramData\msmf-golden-image'
$logDir   = Join-Path $stateDir 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$transcript = Join-Path $logDir ('install-octopus-tentacle-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
Start-Transcript -Path $transcript -Force | Out-Null

function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }

# Path to the installed Tentacle CLI (default install location).
$tentacleExe = Join-Path ${env:ProgramFiles} 'Octopus Deploy\Tentacle\Tentacle.exe'

# Wrapper that runs Tentacle.exe, echoes the command (secrets masked) and throws
# on a non-zero exit code.
function Invoke-Tentacle {
    # NOTE: parameter is deliberately NOT named $Args (that shadows an automatic
    # variable). ValueFromRemainingArguments captures every token - including
    # ones that look like switches (--instance, --if-blank) - as plain strings.
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $TentacleArgs)

    $display = @($TentacleArgs | ForEach-Object {
        if ($_ -match '^API-') { 'API-********' } else { $_ }
    }) -join ' '
    Write-Host "    Tentacle $display"

    & $tentacleExe @TentacleArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Tentacle command failed (exit $LASTEXITCODE): $display"
    }
}

try {
    # =========================================================================
    # 1) Install the Tentacle MSI (idempotent)
    # =========================================================================
    if ((Test-Path $tentacleExe) -and -not $Force) {
        Write-Step "Octopus Tentacle already installed at '$tentacleExe'; skipping MSI."
    }
    else {
        Write-Step "Downloading Octopus Tentacle from $TentacleDownloadUrl"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $msiPath = Join-Path $env:TEMP 'Octopus.Tentacle.x64.msi'
        Invoke-WebRequest -Uri $TentacleDownloadUrl -OutFile $msiPath -UseBasicParsing -MaximumRedirection 5

        # ------------------------------------------------------------------
        # Integrity check BEFORE the MSI runs as SYSTEM (and gets baked into
        # every VM cloned from this image). Fails the build on any mismatch.
        # ------------------------------------------------------------------
        if (-not [string]::IsNullOrWhiteSpace($TentacleMsiSha256)) {
            Write-Step 'Verifying Tentacle MSI SHA256 checksum'
            $expectedHash = $TentacleMsiSha256.Trim().ToUpperInvariant()
            $actualHash   = (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actualHash -ne $expectedHash) {
                Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
                throw ("Tentacle MSI SHA256 mismatch - refusing to install. " +
                       "Expected $expectedHash but downloaded file is $actualHash. " +
                       "The download may have been tampered with, or the pinned hash is stale.")
            }
            Write-Host "    SHA256 OK: $actualHash"
        }
        else {
            Write-Warning ('OCTOPUS_TENTACLE_MSI_SHA256 / -TentacleMsiSha256 not set - ' +
                'installing the downloaded MSI WITHOUT integrity verification. ' +
                'Pin the Tentacle version and supply its SHA256 for production golden images.')
        }

        Write-Step 'Installing Octopus Tentacle (msiexec /quiet)'
        $msiLog = Join-Path $logDir 'tentacle-msi.log'
        $proc = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList @('/i', "`"$msiPath`"", '/quiet', '/norestart', '/l*v', "`"$msiLog`"") `
            -Wait -PassThru
        # 0 = success, 3010 = success but reboot required.
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "Tentacle MSI install failed (exit $($proc.ExitCode)). See $msiLog"
        }
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $tentacleExe)) {
        throw "Tentacle.exe not found at '$tentacleExe' after install."
    }

    # Stage a copy of this script into the image so Stage-2 first-boot automation
    # can invoke the exact same registration logic.
    try {
        $selfPath = $PSCommandPath
        if ($selfPath -and (Test-Path $selfPath)) {
            Copy-Item -Path $selfPath -Destination (Join-Path $stateDir 'install-octopus-tentacle.ps1') -Force
        }
    }
    catch { Write-Warning "Could not stage script copy: $($_.Exception.Message)" }

    # =========================================================================
    # 2) Register (only when asked). Skipped for the generalized golden image.
    # =========================================================================
    if (-not $RegisterWithServer) {
        Write-Step 'RegisterWithServer=$false -> Tentacle installed + staged only.'
        Write-Host  '    Instance, unique certificate and registration are created at first boot' -ForegroundColor Yellow
        Write-Host  '    (Stage-2 runs this script with -RegisterWithServer:$true).' -ForegroundColor Yellow

        # Marker for image traceability.
        [pscustomobject]@{
            component    = 'octopus-tentacle'
            installedUtc = (Get-Date).ToUniversalTime().ToString('u')
            registered   = $false
            note         = 'Registration deferred to first boot (golden-image best practice).'
        } | ConvertTo-Json | Set-Content -Path (Join-Path $stateDir 'octopus-tentacle.marker.json') -Encoding UTF8 -Force

        Write-Step 'Octopus Tentacle install (bake-only) complete.'
        return
    }

    # --- Validate inputs required for registration ---------------------------
    if ([string]::IsNullOrWhiteSpace($ServerUrl)) { throw 'OCTOPUS_SERVER_URL / -ServerUrl is required to register.' }
    if ([string]::IsNullOrWhiteSpace($ApiKey))    { throw 'OCTOPUS_API_KEY / -ApiKey is required to register.' }
    if ($Roles.Count -eq 0)                       { throw 'At least one role (OCTOPUS_ROLES / -Roles) is required.' }
    if ($Environments.Count -eq 0)                { throw 'At least one environment (OCTOPUS_ENVIRONMENT / -Environments) is required.' }

    $configPath = Join-Path $OctopusHome (Join-Path $InstanceName 'Tentacle.config')
    $appDir     = Join-Path $OctopusHome 'Applications'
    $isListening = ($CommunicationMode -eq 'Listen')

    # --- Fresh instance: create instance + UNIQUE certificate + reset trust ---
    if ((-not (Test-Path $configPath)) -or $Force) {
        Write-Step "Creating Tentacle instance '$InstanceName'"
        New-Item -ItemType Directory -Path (Split-Path $configPath) -Force | Out-Null
        Invoke-Tentacle create-instance --instance $InstanceName --config $configPath
        Write-Step 'Generating a unique Tentacle certificate (if blank)'
        Invoke-Tentacle new-certificate --instance $InstanceName --if-blank
        Invoke-Tentacle configure --instance $InstanceName --reset-trust
    }
    else {
        Write-Step "Tentacle instance '$InstanceName' already exists; reconfiguring."
    }

    # --- Configure home / app dir / comms style ------------------------------
    Write-Step "Configuring Tentacle ($CommunicationMode mode)"
    Invoke-Tentacle configure --instance $InstanceName --home $OctopusHome --app $appDir

    if ($isListening) {
        # Listening (Octopus Server -> Tentacle over $ListenPort).
        Invoke-Tentacle configure --instance $InstanceName --port $ListenPort --noListen False

        # Optionally pin trust to the server thumbprint (register-with also
        # establishes trust via the API key, so this is belt-and-suspenders).
        if (-not [string]::IsNullOrWhiteSpace($ServerThumbprint)) {
            Invoke-Tentacle configure --instance $InstanceName --trust $ServerThumbprint
        }

        # Open the listening port in the Windows firewall.
        $ruleName = "MSMF-Octopus-Tentacle-$ListenPort"
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort $ListenPort -Profile Any | Out-Null
        }
    }
    else {
        # Polling (Tentacle -> Octopus Server over $ServerCommsPort). No inbound port.
        Invoke-Tentacle configure --instance $InstanceName --noListen True
    }

    # --- Install + start the Windows service (idempotent) --------------------
    $existingSvc = Get-Service -Name 'OctopusDeploy Tentacle*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match [regex]::Escape($InstanceName) -or $_.DisplayName -match [regex]::Escape($InstanceName) }

    if (-not $existingSvc) {
        Write-Step 'Installing and starting the Tentacle Windows service'
        Invoke-Tentacle service --instance $InstanceName --install --start
    }
    else {
        Write-Step 'Tentacle service already installed; ensuring it is running'
        if ($existingSvc.Status -ne 'Running') { Start-Service -Name $existingSvc.Name }
    }

    # --- Register the machine with Octopus (idempotent via --force) ----------
    Write-Step "Registering '$MachineName' with Octopus at $ServerUrl (space '$Space')"

    $regArgs = [System.Collections.Generic.List[string]]::new()
    $regArgs.AddRange([string[]]@('register-with',
        '--instance', $InstanceName,
        '--server',   $ServerUrl,
        '--apiKey',   $ApiKey,
        '--space',    $Space,
        '--name',     $MachineName))

    foreach ($r in $Roles)        { $regArgs.Add('--role');        $regArgs.Add($r) }
    foreach ($e in $Environments) { $regArgs.Add('--environment'); $regArgs.Add($e) }

    if ($isListening) {
        $regArgs.AddRange([string[]]@('--comms-style', 'TentaclePassive'))
        $regArgs.AddRange([string[]]@('--tentacle-comms-port', "$ListenPort"))
        # Server must be able to reach the Tentacle: prefer an explicit public
        # hostname/IP; otherwise fall back to the machine name.
        $publicName = if ($PublicHostName) { $PublicHostName } else { $MachineName }
        $regArgs.AddRange([string[]]@('--publicHostName', $publicName))
    }
    else {
        $regArgs.AddRange([string[]]@('--comms-style', 'TentacleActive'))
        $regArgs.AddRange([string[]]@('--server-comms-port', "$ServerCommsPort"))
    }

    # --force overwrites an existing machine of the same name -> idempotent.
    $regArgs.AddRange([string[]]@('--force', '--console'))

    # Splat the array (must be @variable, NOT @(...)) so each token is a
    # separate argument to Tentacle.exe.
    $regArgsArray = $regArgs.ToArray()
    Invoke-Tentacle @regArgsArray

    # --- Verify + marker -----------------------------------------------------
    Write-Step 'Verifying Tentacle thumbprint'
    & $tentacleExe show-thumbprint --instance $InstanceName --nologo
    if ($LASTEXITCODE -ne 0) { throw "Failed to read Tentacle thumbprint (exit $LASTEXITCODE)." }

    [pscustomobject]@{
        component     = 'octopus-tentacle'
        installedUtc  = (Get-Date).ToUniversalTime().ToString('u')
        registered    = $true
        instance      = $InstanceName
        machineName   = $MachineName
        server        = $ServerUrl
        space         = $Space
        commsStyle    = $CommunicationMode
        roles         = ($Roles -join ',')
        environments  = ($Environments -join ',')
    } | ConvertTo-Json | Set-Content -Path (Join-Path $stateDir 'octopus-tentacle.marker.json') -Encoding UTF8 -Force

    Write-Step "Octopus Tentacle registered as '$MachineName' ($CommunicationMode)."
}
catch {
    Write-Error "install-octopus-tentacle.ps1 FAILED: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
