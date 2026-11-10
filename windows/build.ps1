[CmdletBinding()]
param([string]$Version = '', [switch]$SkipTests, [switch]$VerifyInstaller)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
$release = Get-Content -Raw (Join-Path $repo 'release-version.json') | ConvertFrom-Json
if (-not $Version) { $Version = [string]$release.version }
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Version -ne $release.version) { throw 'Package version must match release-version.json.' }
$build = [int]$release.build
if ($build -lt 1 -or $build -gt 65535) { throw 'Invalid release build number.' }
if (-not $IsWindows) { throw 'Run build.ps1 on Windows. macOS can cross-publish but cannot run package or installer validation.' }
$artifacts = Join-Path $PSScriptRoot 'artifacts'
$staging = Join-Path $artifacts ('stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $artifacts, $staging | Out-Null
Push-Location $repo
try {
    $head = & git rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') { throw 'Build requires a valid source commit.' }
    $sourceCommit = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { $head.Trim() }
    if ($sourceCommit -ne $head.Trim()) { throw 'Checked-out commit differs from the requested CI commit.' }
    $dirty = & git status --porcelain --untracked-files=normal
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Release builds require a clean source tree.' }
    if (-not $SkipTests) {
        & dotnet test windows/KeyWoo.Tests/KeyWoo.Tests.csproj -c Release --logger 'trx;LogFileName=windows-tests.trx' --results-directory (Join-Path $artifacts 'tests')
        if ($LASTEXITCODE -ne 0) { throw 'Windows Core tests failed.' }
    }
    $icon = Join-Path $artifacts 'KeyWoo.ico'
    & (Join-Path $PSScriptRoot 'make-icon.ps1') -Source (Join-Path $repo 'Resources/KeyWooIcon.png') -Destination $icon
    & dotnet publish windows/KeyWoo.Windows/KeyWoo.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true "-p:Version=$Version" "-p:ApplicationIcon=$icon" -o $staging
    if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
    Copy-Item (Join-Path $repo 'README.md') (Join-Path $staging 'README.md')
    Copy-Item (Join-Path $repo 'README.en.md') (Join-Path $staging 'README.en.md')
    $notices = Get-Content -Raw (Join-Path $repo 'THIRD-PARTY-NOTICES.md')
    $notices = $notices.Replace('Sources/KeyDance/Resources/KeyboardSounds/','Assets/KeyboardSounds/').Replace('windows/licenses/NAudio-LICENSE.txt','Licenses/NAudio-LICENSE.txt').Replace('Sources/KeyDance/Resources/AI/NOTICE.md',"https://github.com/LeavesLei/KeyWoo/blob/$sourceCommit/Sources/KeyDance/Resources/AI/NOTICE.md")
    $notices | Set-Content -Encoding utf8 (Join-Path $staging 'THIRD-PARTY-NOTICES.md')
    $developerDocs = Join-Path $staging 'windows'
    New-Item -ItemType Directory -Force $developerDocs | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'README.md') (Join-Path $developerDocs 'README.md')
    $documentation = Join-Path $staging 'docs'
    New-Item -ItemType Directory -Force $documentation | Out-Null
    foreach ($document in @('INSTALL.md','INSTALL.en.md','PRIVACY.md','RELEASE-v1.0.md')) {
        Copy-Item (Join-Path $repo "docs/$document") (Join-Path $documentation $document)
    }
    $docAssets = Join-Path $documentation 'assets'
    New-Item -ItemType Directory -Force $docAssets | Out-Null
    Copy-Item (Join-Path $repo 'docs/assets/keywoo-icon.png') $docAssets
    Copy-Item (Join-Path $repo 'release-version.json') (Join-Path $staging 'release-version.json')
    $report = Join-Path $artifacts ((Split-Path -Leaf $staging) + '-assets.json')
    $app = Start-Process -FilePath (Join-Path $staging 'KeyWoo.exe') -ArgumentList @('--verify-assets', ('"' + $report + '"')) -Wait -PassThru
    if ($app.ExitCode -ne 0 -or -not (Test-Path $report)) { throw 'Packaged executable failed its no-device asset/PCM self-check.' }
    $result = Get-Content -Raw $report | ConvertFrom-Json
    if (-not $result.passed -or @($result.presets.PSObject.Properties).Count -ne 25 -or @($result.hiFiPresets.PSObject.Properties).Count -ne 15) { throw 'Packaged asset self-check did not pass for all 25 sounds and 15 recorded Hi-Fi variants.' }
    if (-not $result.keyBurst.Passed) { throw 'Packaged Key Burst drawing and overlay self-check failed.' }
    if (-not $result.edgeGlow.Passed) { throw 'Packaged bottom glow, audio decoding and overlay self-check failed.' }
    if (-not $result.statistics.Passed) { throw 'Packaged statistics interaction and rendering self-check failed.' }
    foreach ($license in @('Licenses/NAudio-LICENSE.txt','Licenses/Microsoft.NETCore.App/THIRD-PARTY-NOTICES.TXT','Assets/KeyboardSounds/THIRD-PARTY-NOTICES.md','Assets/KeyboardSounds/Mechvibes-LICENSE','Assets/KeyboardSounds/kbsim-LICENSE.md')) {
        if (-not (Test-Path (Join-Path $staging $license))) { throw "Missing distributed license: $license" }
    }
    foreach ($framework in @('Microsoft.NETCore.App','Microsoft.WindowsDesktop.App')) {
        $licenseDirectory = Join-Path $staging "Licenses/$framework"
        if (-not ((Test-Path (Join-Path $licenseDirectory 'LICENSE')) -or (Test-Path (Join-Path $licenseDirectory 'LICENSE.TXT')))) { throw "Missing runtime license: $framework" }
    }
    Move-Item -LiteralPath $report -Destination (Join-Path $artifacts 'packaged-assets.json') -Force
    $files = @(Get-ChildItem $staging -File -Recurse | Sort-Object FullName | ForEach-Object {
        @{ path = [IO.Path]::GetRelativePath($staging, $_.FullName).Replace('\','/'); sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = $_.Length }
    })
    $zip = Join-Path $artifacts "KeyWoo-$Version-win-x64.zip"
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -Force
    # Read every compressed entry and compare its extracted bytes to the source.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entries = @($archive.Entries | Where-Object { $_.Name.Length -gt 0 })
        if ($entries.Count -ne $files.Count) { throw 'Archive omitted files.' }
        foreach ($entry in $entries) {
            if ($entry.Name.Length -eq 0) { continue }
            $stream = $entry.Open()
            try { $sha = [Security.Cryptography.SHA256]::Create(); $hash = [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant(); $sha.Dispose() } finally { $stream.Dispose() }
            $relative = $entry.FullName.Replace('\','/')
            $expected = @($files | Where-Object { $_.path -eq $relative })
            if ($expected.Count -ne 1 -or $expected[0].sha256 -ne $hash) { throw "Archive content mismatch: $relative" }
        }
    } finally { $archive.Dispose() }
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    $iscc = if ($compiler) { $compiler.Source } else { Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
    if (-not (Test-Path $iscc)) { throw 'Inno Setup 6.3 or newer is required to build the installer.' }
    & $iscc "/DSourceDir=$staging" "/DAppVersion=$Version" "/DAppBuild=$build" "/DOutputDir=$artifacts" "/DAppIcon=$icon" (Join-Path $PSScriptRoot 'installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $installer = Join-Path $artifacts "KeyWoo-$Version-win-x64-setup.exe"
    if (-not (Test-Path $installer)) { throw 'Installer was not produced.' }
    if ($VerifyInstaller) {
        & (Join-Path $PSScriptRoot 'verify-installer.ps1') -Installer $installer -Version $Version -SourceDirectory $staging -ReportDirectory (Join-Path $artifacts 'installer-tests')
    }
    if ((& git rev-parse HEAD).Trim() -ne $sourceCommit -or (& git status --porcelain --untracked-files=normal)) { throw 'Source tree changed during packaging.' }
    @{
        version=$Version; build=$build; sourceCommit=$sourceCommit; platform='windows'; runtime='win-x64'; selfContained=$true; signed=$false;
        archive=[IO.Path]::GetFileName($zip); sha256=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();
        installer=[IO.Path]::GetFileName($installer); installerSha256=(Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant();
        installerTested=[bool]$VerifyInstaller;
        archiveContentsVerified=$true; packagedPresetCount=@($result.presets.PSObject.Properties).Count; keyBurstVerified=[bool]$result.keyBurst.Passed;
        packagedHiFiPresetCount=@($result.hiFiPresets.PSObject.Properties).Count;
        edgeGlowVerified=[bool]$result.edgeGlow.Passed;
        statisticsVerified=[bool]$result.statistics.Passed;
        devicePlaybackTested=$false; hardwareKeyboardTested=$false; files=$files
    } | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $artifacts "KeyWoo-$Version-win-x64-manifest.json")
    Write-Output "Ready: $zip"
    Write-Output "Ready: $installer"
} finally { Pop-Location }
