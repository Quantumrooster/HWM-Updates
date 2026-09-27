[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$catalogUrl = 'https://quantumrooster.github.io/HWM-Updates/updater/stable.json?repair=' + [guid]::NewGuid().ToString('N')
$updaterFolder = Join-Path $env:ProgramFiles 'Headline\Managed Updater'
$updaterExe = Join-Path $updaterFolder 'HeadlineManagedUpdater.exe'
$work = Join-Path $env:ProgramData 'Headline\ManagedUpdater\Recovery'
$payload = Join-Path $work 'HeadlineManagedUpdater.exe'
$serviceNames = @('HeadlineManagedUpdater', 'Headline Managed Updater')

function Get-UpdaterService {
    foreach ($name in $serviceNames) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service) { return $service }
    }
    return $null
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

$service = Get-UpdaterService
if ($service -and $service.Status -ne 'Stopped') {
    Stop-Service -Name $service.Name
    (Get-Service -Name $service.Name).WaitForStatus('Stopped', [timespan]::FromMinutes(2))
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

if ($service) {
    Start-Service -Name $service.Name
}

& $updaterExe --run-once --force
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
    throw "Managed updater repair completed but forced release check returned $LASTEXITCODE."
}

Write-Host "Recovered Managed Updater to $($catalog.version). HWM release evaluation has been triggered."
