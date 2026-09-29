@echo off
setlocal
set "scriptUrl=https://raw.githubusercontent.com/Quantumrooster/HWM-Updates/main/scripts/Start-HwmStableUpdate.ps1"
set "scriptDir=%ProgramData%\Headline\ManagedUpdater\Scripts"
set "scriptPath=%scriptDir%\Start-HwmStableUpdate.ps1"
set "taskName=Headline-HWM-Stable-Update-Now"

if not exist "%scriptDir%" mkdir "%scriptDir%"
curl.exe -fsSL "%scriptUrl%" -o "%scriptPath%"
if errorlevel 1 exit /b %errorlevel%

schtasks.exe /Create /TN "%taskName%" /RU SYSTEM /RL HIGHEST /SC ONCE /ST 23:59 /F /TR "PowerShell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File %scriptPath%"
if errorlevel 1 exit /b %errorlevel%

schtasks.exe /Run /TN "%taskName%"
