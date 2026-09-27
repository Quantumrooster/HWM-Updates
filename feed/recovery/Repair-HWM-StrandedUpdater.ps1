[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$catalogUrl = 'https://quantumrooster.github.io/HWM-Updates/updater/stable.json?repair=' + [guid]::NewGuid().ToString('N')
$updaterFolder = Join-Path $env:ProgramFiles 'Headline\Managed Updater'
$updaterExe = Join-Path $updaterFolder 'HeadlineManagedUpdater.exe'
$work = Join-Path $env:ProgramData 'Headline\ManagedUpdater\Recovery'
$payload = Join-Path $work 'HeadlineManagedUpdater.exe'
$configPath = Join-Path $env:ProgramData 'Headline\ManagedUpdater\config.json'
$statusPath = Join-Path $env:ProgramData 'Headline\ManagedUpdater\status.json'
$serviceNames = @('HeadlineManagedUpdater', 'Headline Managed Updater')
$taskName = 'Headline Managed Updater 15 Minute Check'
$legacyFeed = 'https://quantumrooster.github.io/HWM-Updates/stable'
$modernFeed = 'https://quantumrooster.github.io/HWM-Updates/managed-v2/stable'
$defaultFeed = 'https://updates.headline.co.nz/managed-client'
$updaterShouldRun = $false

function Get-UpdaterServices {
    $services = @()
    foreach ($name in $serviceNames) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service) { $services += $service }
    }
    return @($services | Sort-Object Name -Unique)
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this recovery from an elevated PowerShell session.'
    }
}

Assert-Admin
New-Item -ItemType Directory -Path $work -Force | Out-Null

$catalogPath = Join-Path $work 'stable-updater.json'
Invoke-WebRequest -Uri $catalogUrl -OutFile $catalogPath -UseBasicParsing
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

if ($catalog.schemaVersion -ne 1 -or $catalog.channel -ne 'stable' -or [version]$catalog.version -lt [version]'0.1.5.0') {
    throw 'Unexpected updater catalog.'
}

Invoke-WebRequest -Uri $catalog.url -OutFile $payload -UseBasicParsing
if ((Get-Item -LiteralPath $payload).Length -ne [long]$catalog.sizeBytes) { throw 'Updater size mismatch.' }
if ((Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash -ne $catalog.sha256) { throw 'Updater hash mismatch.' }
if ([version](Get-Item -LiteralPath $payload).VersionInfo.FileVersion -ne [version]$catalog.version) { throw 'Updater version mismatch.' }

$services = @(Get-UpdaterServices)
$runningServiceNames = @($services | Where-Object Status -ne 'Stopped' | ForEach-Object Name)
$scheduledTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskWasEnabled = $null -ne $scheduledTask -and $scheduledTask.Settings.Enabled

try {
    if ($taskWasEnabled) {
        Disable-ScheduledTask -TaskName $taskName | Out-Null
    }

    foreach ($service in $services) {
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $service.Name
            (Get-Service -Name $service.Name).WaitForStatus('Stopped', [timespan]::FromMinutes(2))
        }
    }

    $processDeadline = (Get-Date).AddSeconds(45)
    do {
        $updaterProcesses = @(Get-Process -Name HeadlineManagedUpdater -ErrorAction SilentlyContinue)
        if ($updaterProcesses.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $processDeadline)
    if ($updaterProcesses.Count -ne 0) {
        throw 'An updater process is still running; no files were replaced.'
    }

    New-Item -ItemType Directory -Path $updaterFolder -Force | Out-Null
    $backup = Join-Path $work ('HeadlineManagedUpdater.previous-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.exe')
    if (Test-Path -LiteralPath $updaterExe) {
        Copy-Item -LiteralPath $updaterExe -Destination $backup -Force
    }
    Copy-Item -LiteralPath $payload -Destination $updaterExe -Force

    $probe = & $updaterExe --probe
    if ($LASTEXITCODE -ne 0 -or $probe.Trim() -ne $catalog.version) {
        if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $updaterExe -Force }
        throw 'Recovered updater did not pass its startup probe; previous binary restored.'
    }

    $originalConfig = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw } else { $null }
    if ($originalConfig) {
        $config = $originalConfig | ConvertFrom-Json
    }
    else {
        $config = [pscustomobject][ordered]@{
            schemaVersion = 1; enabled = $true; channel = 'stable'; manifestBaseUrl = $modernFeed
            checkEveryMinutes = 30; autoInstall = $true; maintenanceStartHour = 0; maintenanceEndHour = 0
            healthVerificationSeconds = 120; allowFileManifestForTesting = $false
        }
    }

    if ($config.PSObject.Properties['enabled'] -and $config.enabled -eq $false) {
        throw 'The Managed Updater is explicitly disabled. The updater binary was repaired, but HWM was not changed.'
    }
    $updaterShouldRun = $true
    $configuredChannel = if ($config.PSObject.Properties['channel']) { [string]$config.channel } else { 'stable' }
    if ($configuredChannel -ne 'stable') {
        throw "This recovery is for Stable endpoints; the configured channel is '$configuredChannel'."
    }
    $configuredFeed = if ($config.PSObject.Properties['manifestBaseUrl']) { [string]$config.manifestBaseUrl } else { $defaultFeed }
    if ($configuredFeed -eq $legacyFeed -or $configuredFeed -eq $defaultFeed) {
        if ($config.PSObject.Properties['manifestBaseUrl']) { $config.manifestBaseUrl = $modernFeed }
        else { $config | Add-Member -NotePropertyName manifestBaseUrl -NotePropertyValue $modernFeed }
    }
    elseif ($configuredFeed -ne $modernFeed) {
        throw "Custom update feed '$configuredFeed' was preserved and requires explicit review."
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
    $configTemp = $configPath + '.repair.tmp'
    [IO.File]::WriteAllText($configTemp, ($config | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $configTemp -Destination $configPath -Force

    Write-Host "Managed Updater $($catalog.version) installed. Running the HWM update now..."
    $runOutput = (& $updaterExe --run-once --force 2>&1 | Out-String).Trim()
    $runExitCode = $LASTEXITCODE
    if ($runOutput) { Write-Host $runOutput }
    if ($runExitCode -ne 0 -and $runExitCode -ne 2) {
        if ($null -eq $originalConfig) { Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }
        else { [IO.File]::WriteAllText($configPath, $originalConfig, [Text.UTF8Encoding]::new($false)) }
        if (Test-Path -LiteralPath $statusPath) {
            Write-Host 'Updater status:'
            Get-Content -LiteralPath $statusPath -Raw | Write-Host
        }
        throw "Forced HWM update returned $runExitCode."
    }
}
finally {
    if ($updaterShouldRun) {
        $canonicalService = Get-Service -Name 'HeadlineManagedUpdater' -ErrorAction SilentlyContinue
        if (-not $canonicalService) {
            & sc.exe create HeadlineManagedUpdater binPath= ('"' + $updaterExe + '"') start= delayed-auto DisplayName= 'Headline Managed Updater' | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not recreate the canonical Managed Updater service.' }
        }
        else {
            & sc.exe config HeadlineManagedUpdater binPath= ('"' + $updaterExe + '"') start= delayed-auto DisplayName= 'Headline Managed Updater' | Out-Null
        }
        $canonicalService = Get-Service -Name 'HeadlineManagedUpdater' -ErrorAction SilentlyContinue
        if ($canonicalService -and $canonicalService.Status -ne 'Running') { Start-Service -Name 'HeadlineManagedUpdater' }
    }
    else {
        foreach ($serviceName in $runningServiceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service -and $service.Status -ne 'Running') { Start-Service -Name $serviceName }
        }
    }
    if ($taskWasEnabled) { Enable-ScheduledTask -TaskName $taskName | Out-Null }
}

$hwmExe = Join-Path $env:ProgramFiles 'Headline\Workstation Monitor\HeadlineWorkstationService.exe'
$hwmVersion = if (Test-Path -LiteralPath $hwmExe) { (Get-Item -LiteralPath $hwmExe).VersionInfo.FileVersion } else { 'Not installed' }
$finalState = if (Test-Path -LiteralPath $statusPath) { (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).state } else { 'No status' }
Write-Host "Recovery completed. Managed Updater: $($catalog.version); HWM service: $hwmVersion; state: $finalState"
