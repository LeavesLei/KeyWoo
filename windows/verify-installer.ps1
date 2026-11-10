[CmdletBinding()]
param([Parameter(Mandatory)][string]$Installer, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$SourceDirectory, [Parameter(Mandatory)][string]$ReportDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# This deliberately installs into the disposable runner's user profile.
# Never silently install/uninstall against a developer's existing KeyWoo.
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or -not $env:RUNNER_TEMP) { throw 'Installer smoke verification is restricted to a disposable GitHub Actions Windows runner.' }
$Installer = [IO.Path]::GetFullPath($Installer)
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
$ReportDirectory = [IO.Path]::GetFullPath($ReportDirectory)
New-Item -ItemType Directory -Force $ReportDirectory | Out-Null
$install = Join-Path $env:RUNNER_TEMP ('KeyWoo-install-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $env:LOCALAPPDATA 'KeyWoo'
$registration = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{B608FC98-62B3-4B21-B82A-BB660B9C3051}_is1'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'KeyWoo.lnk'
if ((Test-Path $data) -or (Test-Path $registration) -or (Test-Path $shortcut)) { throw 'Refusing to touch an existing KeyWoo installation or profile.' }
New-Item -ItemType Directory $data | Out-Null
$settings = Join-Path $data 'settings.json'
$statistics = Join-Path $data 'statistics.json'
'{"Schema":1,"Platform":"windows","Preset":"panda","HiFiEnabled":true,"Volume":0.73}' | Set-Content -Encoding utf8 $settings
'{"installerTestSentinel":true,"count":7}' | Set-Content -Encoding utf8 $statistics
$expected = @{}; foreach ($file in @($settings, $statistics)) { $expected[$file] = (Get-FileHash $file -Algorithm SHA256).Hash }
$payload = @(Get-ChildItem $SourceDirectory -File -Recurse | ForEach-Object {
    @{ path=[IO.Path]::GetRelativePath($SourceDirectory,$_.FullName); sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash }
})
function Assert-DataPreserved {
    foreach ($file in $expected.Keys) {
        if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $expected[$file]) { throw 'Installer changed settings/statistics.' }
    }
}
function Run-Checked([string]$File, [string[]]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Process failed ($($process.ExitCode)): $([IO.Path]::GetFileName($File))" }
}
$result = @{ passed=$false; version=$Version; perUser=$true; hardwareKeyboardTested=$false; devicePlaybackTested=$false }
try {
    foreach ($phase in @('install', 'upgrade')) {
        Run-Checked $Installer @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',("/DIR=`"$install`""),("/LOG=`"$(Join-Path $ReportDirectory "$phase.log")`""))
        if (-not (Test-Path (Join-Path $install 'KeyWoo.exe'))) { throw 'Installed executable is missing.' }
        if (-not (Test-Path $registration) -or (Get-ItemProperty $registration).DisplayVersion -ne $Version) { throw 'Per-user uninstall registration has an incorrect version.' }
        if (-not (Test-Path $shortcut)) { throw 'Start menu shortcut is missing.' }
        $shell = New-Object -ComObject WScript.Shell
        if ($shell.CreateShortcut($shortcut).TargetPath -ne (Join-Path $install 'KeyWoo.exe')) { throw 'Start menu shortcut targets the wrong executable.' }
        foreach ($file in $payload) {
            $installedFile = Join-Path $install $file.path
            if (-not (Test-Path $installedFile) -or (Get-FileHash $installedFile -Algorithm SHA256).Hash -ne $file.sha256) { throw "Installed file differs from staging: $($file.path)" }
        }
        Assert-DataPreserved
        $result[$phase+'Passed']=$true
    }
    $report = Join-Path $ReportDirectory 'installed-assets.json'
    Run-Checked (Join-Path $install 'KeyWoo.exe') @('--verify-assets',("`"$report`""))
    $assets = Get-Content -Raw $report | ConvertFrom-Json
    if (-not $assets.passed -or @($assets.presets.PSObject.Properties).Count -ne 25 -or @($assets.hiFiPresets.PSObject.Properties).Count -ne 15) { throw 'Installed app asset self-check failed.' }
    if (-not $assets.keyBurst.Passed) { throw 'Installed Key Burst drawing and overlay self-check failed.' }
    if (-not $assets.edgeGlow.Passed) { throw 'Installed bottom glow and system-audio self-check failed.' }
    if (-not $assets.statistics.Passed) { throw 'Installed statistics interaction and rendering self-check failed.' }
    $result.installedKeyBurstVerified=[bool]$assets.keyBurst.Passed
    $result.installedEdgeGlowVerified=[bool]$assets.edgeGlow.Passed
    $result.installedStatisticsVerified=[bool]$assets.statistics.Passed
    $result.installedPresetCount=@($assets.presets.PSObject.Properties).Count
    $result.installedHiFiPresetCount=@($assets.hiFiPresets.PSObject.Properties).Count
    Run-Checked (Join-Path $install 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',("/LOG=`"$(Join-Path $ReportDirectory 'uninstall.log')`""))
    if ((Test-Path (Join-Path $install 'KeyWoo.exe')) -or (Test-Path $registration) -or (Test-Path $shortcut)) { throw 'Uninstaller left the application or registration behind.' }
    Assert-DataPreserved
    $result.uninstallPassed=$true; $result.settingsAndStatisticsPreserved=$true; $result.installedFilesVerified=$payload.Count; $result.passed=$true
} catch {
    $result.error=$_.Exception.Message
    throw
} finally {
    $result | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $ReportDirectory 'result.json')
    # Only files with our known fixture hashes may be removed.
    foreach ($file in $expected.Keys) {
        if ((Test-Path $file) -and (Get-FileHash $file -Algorithm SHA256).Hash -eq $expected[$file]) { Remove-Item -LiteralPath $file }
    }
    if ((Test-Path $data) -and @(Get-ChildItem -Force $data).Count -eq 0) { Remove-Item -LiteralPath $data }
}
