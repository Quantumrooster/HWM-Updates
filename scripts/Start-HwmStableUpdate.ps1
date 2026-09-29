[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this command in an elevated PowerShell or remote SYSTEM terminal.'
}

$scriptUrl = 'https://raw.githubusercontent.com/Quantumrooster/HWM-Updates/main/scripts/Invoke-HwmStableUpdate.ps1'
$folder = Join-Path $env:ProgramData 'Headline\ManagedUpdater\Scripts'
$scriptPath = Join-Path $folder 'Invoke-HwmStableUpdate.ps1'
$taskName = 'Headline-HWM-Stable-Update-Now'

New-Item -ItemType Directory -Path $folder -Force | Out-Null
Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath -UseBasicParsing

$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '"')
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$task = New-ScheduledTask -Action $action -Principal $principal
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Output 'Headline Stable update started in the background. Check the HWM agent version in MSP Operations in a few minutes.'
