[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$catalogUrl = 'https://quantumrooster.github.io/HWM-Updates/updater/stable.json?repair=' + [guid]::NewGuid().ToString('N')
$updaterFolder = Join-Path $env:ProgramFiles 'Headline\Managed Updater'
$updaterExe = Join-Path $updaterFolder 'HeadlineManagedUpdater.exe'
$work = Join-Path $env:ProgramData 'Headline\ManagedUpdater\Recovery'
$payload = Join-Path $work 'HeadlineManagedUpdater.exe'
$serviceNames = @('HeadlineManagedUpdater', 'Headline Managed Updater')
$taskName = 'Headline Managed Updater 15 Minute Check'

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

    Write-Host "Managed Updater $($catalog.version) installed. Running the HWM update now..."
    $runOutput = (& $updaterExe --run-once --force 2>&1 | Out-String).Trim()
    $runExitCode = $LASTEXITCODE
    if ($runOutput) { Write-Host $runOutput }
    if ($runExitCode -ne 0 -and $runExitCode -ne 2) {
        $statusPath = Join-Path $env:ProgramData 'Headline\ManagedUpdater\status.json'
        if (Test-Path -LiteralPath $statusPath) {
            Write-Host 'Updater status:'
            Get-Content -LiteralPath $statusPath -Raw | Write-Host
        }
        throw "Forced HWM update returned $runExitCode."
    }
}
finally {
    foreach ($serviceName in $runningServiceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running') { Start-Service -Name $serviceName }
    }
    if ($taskWasEnabled) { Enable-ScheduledTask -TaskName $taskName | Out-Null }
}

$hwmExe = Join-Path $env:ProgramFiles 'Headline\Workstation Monitor\HeadlineWorkstationService.exe'
$hwmVersion = if (Test-Path -LiteralPath $hwmExe) { (Get-Item -LiteralPath $hwmExe).VersionInfo.FileVersion } else { 'Not installed' }
Write-Host "Recovery completed. Managed Updater: $($catalog.version); HWM service: $hwmVersion"
