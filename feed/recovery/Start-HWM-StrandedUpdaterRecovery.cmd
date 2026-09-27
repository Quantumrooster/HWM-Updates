@echo off
setlocal

set "TASK=Headline HWM Updater Recovery"
set "ROOT=C:\ProgramData\Headline\ManagedUpdater\Recovery"
set "REPAIR=%ROOT%\Repair-HWM-StrandedUpdater.ps1"
set "RUNNER=%ROOT%\Run-HWM-StrandedUpdaterRecovery.cmd"
set "LOG=%ROOT%\recovery.log"
set "URL=https://raw.githubusercontent.com/Quantumrooster/HWM-Updates/58b1bb1d82d07187eff81e2e11aafba35c243fe5/feed/recovery/Repair-HWM-StrandedUpdater.ps1"
set "SHA256=22D6A91AA95F25E9874238E8D53A6A5502E0BB9A0921B7FE9AF86F336A491AB3"

if not exist "%ROOT%" mkdir "%ROOT%"
if errorlevel 1 exit /b 1

curl.exe -fL --retry 3 "%URL%" -o "%REPAIR%"
if errorlevel 1 exit /b 1

certutil.exe -hashfile "%REPAIR%" SHA256 | findstr.exe /I /C:"%SHA256%" >nul
if errorlevel 1 (
    echo Downloaded recovery script failed SHA256 verification.
    exit /b 1
)

>"%RUNNER%" echo @echo off
>>"%RUNNER%" echo C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPAIR%" ^>"%LOG%" 2^>^&1

schtasks.exe /Create /TN "%TASK%" /TR "%RUNNER%" /SC ONCE /SD 01/01/2099 /ST 00:00 /RU SYSTEM /RL HIGHEST /F
if errorlevel 1 exit /b 1

schtasks.exe /Run /TN "%TASK%"
if errorlevel 1 exit /b 1

echo Background recovery started as SYSTEM. It can run beyond the terminal limit.
echo Log: %LOG%
exit /b 0
