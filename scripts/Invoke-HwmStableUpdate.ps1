[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$updaterServiceName = 'HeadlineManagedUpdater'
$updaterFolder = Join-Path $env:ProgramFiles 'Headline\Managed Updater'
$updaterExe = Join-Path $updaterFolder 'HeadlineManagedUpdater.exe'
$updaterData = Join-Path $env:ProgramData 'Headline\ManagedUpdater'
$configFile = Join-Path $updaterData 'config.json'
$catalogUrl = 'https://quantumrooster.github.io/HWM-Updates/updater/stable.json'
$feedRoot = 'https://quantumrooster.github.io/HWM-Updates/managed-v2/stable'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this command in an elevated PowerShell or remote SYSTEM terminal.'
}

New-Item -ItemType Directory -Path $updaterFolder, $updaterData -Force | Out-Null
$temporaryUpdater = Join-Path $env:TEMP ('HeadlineManagedUpdater-' + [guid]::NewGuid().ToString('N') + '.exe')

try {
    $catalog = Invoke-RestMethod -Uri ($catalogUrl + '?hwmcb=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    if ($catalog.version -ne '0.1.6.0') { throw "Unexpected Stable updater version: $($catalog.version)" }

    Invoke-WebRequest -Uri $catalog.url -OutFile $temporaryUpdater -UseBasicParsing
    $hash = (Get-FileHash -LiteralPath $temporaryUpdater -Algorithm SHA256).Hash
    if ($hash -ne $catalog.sha256) { throw 'Updater download checksum verification failed.' }
    if ((Get-Item -LiteralPath $temporaryUpdater).VersionInfo.FileVersion -ne $catalog.version) {
        throw 'Downloaded updater version does not match the Stable catalog.'
    }

    $service = Get-Service -Name $updaterServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name $updaterServiceName -Force
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
    }

    if (Test-Path -LiteralPath $updaterExe) {
        $backup = $updaterExe + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        [IO.File]::Replace($temporaryUpdater, $updaterExe, $backup)
    } else {
        Move-Item -LiteralPath $temporaryUpdater -Destination $updaterExe
    }
    if ($service) {
        & sc.exe config $updaterServiceName binPath= ('"' + $updaterExe + '"') start= auto | Out-Null
    } else {
        New-Service -Name $updaterServiceName -BinaryPathName ('"' + $updaterExe + '"') -DisplayName 'Headline Managed Updater' -StartupType Automatic | Out-Null
    }

    [ordered]@{
        schemaVersion = 1
        enabled = $true
        channel = 'stable'
        manifestBaseUrl = $feedRoot
        checkEveryMinutes = 30
        autoInstall = $true
        maintenanceStartHour = 0
        maintenanceEndHour = 0
        healthVerificationSeconds = 120
        allowFileManifestForTesting = $false
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configFile -Encoding UTF8

    & $updaterExe --run-once --force
    if ($LASTEXITCODE -ne 0) { throw "HWM updater returned exit code $LASTEXITCODE." }

    Start-Service -Name $updaterServiceName
    $serviceVersion = (Get-Item (Join-Path $env:ProgramFiles 'Headline\Workstation Monitor\HeadlineWorkstationService.exe')).VersionInfo.FileVersion
    Write-Output "HWM Stable update completed. Service version: $serviceVersion"
}
finally {
    if (Test-Path -LiteralPath $temporaryUpdater) { Remove-Item -LiteralPath $temporaryUpdater -Force }
}
