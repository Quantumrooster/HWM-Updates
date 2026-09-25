# Controlled HWM agent update only. Does not install Windows or application updates.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'HCSPC2025') { throw 'Restricted to HCSPC2025.' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run in Administrator PowerShell.' }
$updater = Join-Path $env:ProgramFiles 'Headline\Managed Updater\HeadlineManagedUpdater.exe'
if ([version](Get-Item -LiteralPath $updater).VersionInfo.FileVersion -lt [version]'0.1.4.0') { throw 'Managed Updater 0.1.4.0 or later is required. Complete the verified updater bootstrap first.' }
$data = Join-Path $env:ProgramData 'Headline\ManagedUpdater'
$config = Get-Content (Join-Path $data 'config.json') -Raw | ConvertFrom-Json
if ($config.Channel -ne 'dev') { throw 'The PC must already be configured for DEV.' }
$base = [string]$config.ManifestBaseUrl
if ($base -match '\{channel\}') { $uri = $base.Replace('{channel}', 'dev') }
else { $uri = $base.TrimEnd('/') + '/dev.json' }
if ($uri -ne 'https://quantumrooster.github.io/HWM-Updates/dev/dev.json') { throw 'Unexpected DEV manifest URL.' }
$manifest = Invoke-RestMethod ($uri + '?inventory=' + [guid]::NewGuid().ToString('N'))
if ($manifest.releaseVersion -ne '0.2.5.24' -or $manifest.minimumUpdaterVersion -ne '0.1.4.0' -or
    $manifest.components.hwmServiceVersion -ne '0.2.5.17' -or $manifest.components.hwmTrayVersion -ne '1.0.0.16') { throw 'The DEV feed is not the reviewed inventory release. Stop and review the new feed.' }
$hwm = Join-Path $env:ProgramFiles 'Headline\Workstation Monitor'
if ([version](Get-Item (Join-Path $hwm 'HeadlineWorkstationService.exe')).VersionInfo.FileVersion -gt [version]'0.2.5.17' -or
    [version](Get-Item (Join-Path $hwm 'HeadlineWorkstationMonitor.exe')).VersionInfo.FileVersion -gt [version]'1.0.0.16') { throw 'Newer HWM components are installed; refusing this test.' }
$started = [DateTime]::UtcNow
# The updater enforces its global lock, downloaded SHA/size, minimum version,
# component versions, health verification and rollback.
& $updater --run-once --force
if ($LASTEXITCODE -ne 0) { throw "Updater failed (exit $LASTEXITCODE). Review updater status before retrying." }
$status = Get-Content (Join-Path $data 'status.json') -Raw | ConvertFrom-Json
$status | Format-List
if ($status.LastInstalledReleaseVersion -ne '0.2.5.24') { throw 'Expected release was not installed.' }
$healthPath = Join-Path $env:ProgramData 'Headline\WorkstationMonitor\health.json'
$deadline = [DateTime]::UtcNow.AddMinutes(5)
do {
    $health = $null
    try {
        if ((Get-Item $healthPath).LastWriteTimeUtc -ge $started) {
            $candidate = Get-Content $healthPath -Raw | ConvertFrom-Json
            if ($candidate.AgentVersion -eq '0.2.5.17' -and $candidate.UpdateInventoryAvailable -eq $true -and $candidate.WindowsUpdateAvailable -eq $true) { $health = $candidate }
        }
    } catch { Write-Verbose $_ }
    if ($health) { break }
    Start-Sleep -Seconds 5
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $health) { throw 'Fresh successful inventory was not received within five minutes. Keep API production deployment on hold.' }
$evidence = Join-Path $data ('inventory-0.2.5.24-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
$health | Select-Object ComputerName,AgentVersion,SchemaVersion,IntuneEnrolled,IntuneEnrollmentDetail,IntuneEnrollmentCheckedUtc,UpdateManagement,WindowsUpdateAvailable,WindowsUpdateLastCheckedLocal,WindowsUpdateItems,UpdateInventoryAvailable,UpdateInventorySummary,UpdateInventoryCheckedLocal,UpdateApplications | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidence -Encoding UTF8
$health | Select-Object IntuneEnrolled,IntuneEnrollmentDetail,IntuneEnrollmentCheckedUtc,UpdateManagement | Format-List
$health.WindowsUpdateItems | Format-List
$health.UpdateApplications | Format-List
Write-Host "Inventory captured: $evidence"
Write-Host 'Compare this inventory with installed apps and Windows Update, and confirm the server received the matching heartbeat before deploying the API UI.'

