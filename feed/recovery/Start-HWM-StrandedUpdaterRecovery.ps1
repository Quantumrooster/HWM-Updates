[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'Headline HWM Updater Recovery'
$root = Join-Path $env:ProgramData 'Headline\ManagedUpdater\Recovery'
$repairPath = Join-Path $root 'Repair-HWM-StrandedUpdater.ps1'
$runnerPath = Join-Path $root 'Run-HWM-StrandedUpdaterRecovery.ps1'
$logPath = Join-Path $root 'recovery.log'
$repairUrl = 'https://raw.githubusercontent.com/Quantumrooster/HWM-Updates/58b1bb1d82d07187eff81e2e11aafba35c243fe5/feed/recovery/Repair-HWM-StrandedUpdater.ps1'
$repairSha256 = '22D6A91AA95F25E9874238E8D53A6A5502E0BB9A0921B7FE9AF86F336A491AB3'

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') {
    Write-Output "Recovery is already running. Log: $logPath"
    exit 0
}

New-Item -ItemType Directory -Path $root -Force | Out-Null
Invoke-WebRequest -Uri $repairUrl -OutFile $repairPath -UseBasicParsing
if ((Get-FileHash -LiteralPath $repairPath -Algorithm SHA256).Hash -ne $repairSha256) {
    throw 'Downloaded recovery script failed SHA256 verification.'
}

$runner = @"
`$ErrorActionPreference = 'Stop'
Start-Transcript -Path '$logPath' -Force
try {
    & '$repairPath'
    Write-Host 'Background recovery finished successfully.'
}
catch {
    Write-Error (`$_ | Out-String)
    exit 1
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
"@
[IO.File]::WriteAllText($runnerPath, $runner, [Text.UTF8Encoding]::new($false))

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $powershell -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $runnerPath + '"')
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(10)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Output "Background recovery started as SYSTEM. It can run beyond the terminal limit. Log: $logPath"
