[CmdletBinding()]
param([string]$SourcePath='_hwm', [switch]$Publish)
$ErrorActionPreference='Stop'
$source=(Resolve-Path $SourcePath).Path
$stable=Invoke-RestMethod ('https://quantumrooster.github.io/HWM-Updates/managed-v2/stable/stable.json?armcb='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
if ($stable.sourceCommit -notmatch '^[a-f0-9]{40}$' -or $stable.validation.passed -ne $true -or $stable.validation.sourceCommit -ne $stable.sourceCommit) {throw 'Stable source validation is missing.'}
if (-not [string]::IsNullOrWhiteSpace($stable.components.hcsAutomationVersion)) {throw 'Stable adds HCS Automation; an ARM64 build must be supported before publication.'}
# Resolve the immutable support commit from the checked-out private source.
$support=(git -C $source rev-parse HEAD).Trim()
$base='177996e208f381b931da96d72b122c2901bcda91'
$currentPath='feed/arm64/managed-v2/stable/stable.json'
if(Test-Path $currentPath) {
    $current=Get-Content $currentPath -Raw | ConvertFrom-Json
    if([version]$current.releaseVersion -gt [version]$stable.releaseVersion){throw 'Refusing ARM64 release downgrade.'}
    if($current.sourceCommit -eq $stable.sourceCommit -and $current.arm64SupportCommit -eq $support){Write-Host 'ARM64 Stable already matches validated Stable source.'; return}
}
$patch=Join-Path $env:RUNNER_TEMP 'hwm-arm64-support.patch'
git -C $source fetch --depth 1 origin $base $stable.sourceCommit
if($LASTEXITCODE){throw 'Cannot fetch validated Stable source.'}
git -C $source diff --binary $base $support | Set-Content -LiteralPath $patch -Encoding utf8
git -C $source checkout --detach $stable.sourceCommit
if($LASTEXITCODE){throw 'Cannot select validated Stable source.'}
git -C $source apply --check $patch
if($LASTEXITCODE){throw 'ARM64 overlay conflicts with new Stable; publication stopped.'}
git -C $source apply $patch
if($LASTEXITCODE){throw 'ARM64 overlay failed.'}
dotnet run --project "$source/tests/Arm64UpdateChecks/Arm64UpdateChecks.csproj" -c Release
if($LASTEXITCODE){throw 'Architecture tests failed.'}
$out=Join-Path $env:RUNNER_TEMP 'hwm-arm64-build'
dotnet publish "$source/tests/TrayFixture/TrayFixture.csproj" -c Release -r win-arm64 --self-contained true -o "$out/fixture"
if($LASTEXITCODE){throw 'ARM64 fixture build failed.'}
dotnet run --project "$source/tests/UpdaterLockTests/UpdaterLockTests.csproj" -c Release -- "$out/fixture"
if($LASTEXITCODE){throw 'Native ARM64 file replacement/rollback/locking tests failed.'}
$releaseVersion=[version]$stable.releaseVersion
# ARM64 updater version advances with Stable; bump major for support-only fixes.
$updaterVersion="1.$($releaseVersion.Minor).$($releaseVersion.Build).$($releaseVersion.Revision)"
dotnet publish "$source/ServiceProject/HeadlineWorkstationService.csproj" -c Release -r win-arm64 --self-contained true -o "$out/service" -p:DebugType=None -p:DebugSymbols=false
if($LASTEXITCODE){throw 'ARM64 service build failed.'}
dotnet publish "$source/HeadlineWorkstationMonitor/HeadlineWorkstationMonitor.csproj" -c Release -r win-arm64 --self-contained true -o "$out/tray" -p:DebugType=None -p:DebugSymbols=false
if($LASTEXITCODE){throw 'ARM64 tray build failed.'}
dotnet publish "$source/HeadlineManagedUpdater/HeadlineManagedUpdater.csproj" -c Release -r win-arm64 --self-contained true -o "$out/updater" -p:DebugType=None -p:DebugSymbols=false "-p:Version=$updaterVersion" "-p:AssemblyVersion=$updaterVersion" "-p:FileVersion=$updaterVersion"
if($LASTEXITCODE){throw 'ARM64 updater build failed.'}
$service="$out/service/HeadlineWorkstationService.exe";$tray="$out/tray/HeadlineWorkstationMonitor.exe";$updater="$out/updater/HeadlineManagedUpdater.exe"
if((Get-Item $service).VersionInfo.FileVersion -ne $stable.components.hwmServiceVersion -or (Get-Item $tray).VersionInfo.FileVersion -ne $stable.components.hwmTrayVersion){throw 'ARM64 component versions do not match Stable declaration.'}
$probe=& $updater --probe
if($LASTEXITCODE -ne 0 -or $probe.Trim() -ne $updaterVersion){throw 'Native ARM64 updater startup probe failed.'}
$releaseFolder="feed/arm64/releases/$releaseVersion"
if(Test-Path $releaseFolder){throw 'ARM64 versioned release already exists; do not overwrite immutable payloads.'}
New-Item -ItemType Directory -Force -Path $releaseFolder,'feed/arm64/updater','feed/arm64/managed-v2/stable' | Out-Null
$zip="$releaseFolder/Headline-HWM-$releaseVersion-win-arm64.zip"
Compress-Archive -LiteralPath @($service,$tray) -DestinationPath $zip -CompressionLevel Optimal
Copy-Item -LiteralPath $updater -Destination "$releaseFolder/HeadlineManagedUpdater.exe"
$baseUrl='https://raw.githubusercontent.com/Quantumrooster/HWM-Updates/main/feed/arm64'
$catalog=[ordered]@{schemaVersion=1;runtime='win-arm64';sourceCommit=$stable.sourceCommit;arm64SupportCommit=$support;channel='stable';minimumMaintenanceProtocol=1;version=$updaterVersion;url="$baseUrl/releases/$releaseVersion/HeadlineManagedUpdater.exe";sha256=(Get-FileHash $updater).Hash;sizeBytes=(Get-Item $updater).Length}
$manifest=[ordered]@{schemaVersion=1;runtime='win-arm64';channel='stable';releaseVersion=[string]$releaseVersion;sourceCommit=$stable.sourceCommit;arm64SupportCommit=$support;publishedUtc=[DateTimeOffset]::UtcNow.ToString('o');urgent=$false;allowDowngrade=$false;minimumUpdaterVersion=$updaterVersion;releaseNotes='Native ARM64 build from validated Stable source; architecture-checked automatic updates and native ARM64 updater lock/rollback regression tests.';components=$stable.components;package=[ordered]@{url="$baseUrl/releases/$releaseVersion/Headline-HWM-$releaseVersion-win-arm64.zip";sha256=(Get-FileHash $zip).Hash;sizeBytes=(Get-Item $zip).Length};validation=[ordered]@{passed=$true;nativeArm64=$true;sourceCommit=$stable.sourceCommit;runUrl="https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"}}
$catalog | ConvertTo-Json -Depth 8 | Set-Content feed/arm64/updater/stable.json -Encoding utf8
$manifest | ConvertTo-Json -Depth 8 | Set-Content $currentPath -Encoding utf8
if($Publish) {
    git config user.name 'Headline HWM Release Bot'
    git config user.email '248761542+Quantumrooster@users.noreply.github.com'
    git add feed/arm64
    $staged=@(git diff --cached --name-only)
    if($staged | Where-Object {$_ -notlike 'feed/arm64/*'}){throw 'Unexpected staged files.'}
    git commit -m "release: ARM64 Stable $releaseVersion from validated source"
    if($LASTEXITCODE){throw 'Feed commit failed.'}
    git pull --rebase origin main
    if($LASTEXITCODE){throw 'Feed rebase failed.'}
    git push origin HEAD:main
    if($LASTEXITCODE){throw 'Feed push failed.'}
    Write-Host 'ARM64 direct HTTPS feed published; no full-site deployment required.'
}


