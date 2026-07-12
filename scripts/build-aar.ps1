[CmdletBinding()]
param(
    [string]$AndroidSdk,
    [switch]$RebuildNative
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $RepositoryRoot 'config\dependencies.properties'
$DependenciesRoot = Join-Path $RepositoryRoot '.deps'
$Media3Path = Join-Path $DependenciesRoot 'media3'
$DecoderModulePath = Join-Path $Media3Path 'libraries\decoder_ffmpeg'
$FfmpegPath = Join-Path $DecoderModulePath 'src\main\jni\ffmpeg'
$DistPath = Join-Path $RepositoryRoot 'dist'
$GitBashPath = 'C:\Program Files\Git\bin\bash.exe'
$WindowsHostPlatform = 'windows-x86_64'
$SupportedAbis = @('armeabi-v7a', 'arm64-v8a', 'x86', 'x86_64')

function Read-Properties {
    param([Parameter(Mandatory)][string]$Path)

    $properties = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (!$trimmed -or $trimmed.StartsWith('#')) {
            continue
        }
        $parts = $trimmed.Split('=', 2)
        $properties[$parts[0].Trim()] = $parts[1].Trim()
    }
    return $properties
}

function Convert-ToMsysPath {
    param([Parameter(Mandatory)][string]$WindowsPath)

    $resolved = (Resolve-Path -LiteralPath $WindowsPath).Path.Replace('\', '/')
    if ($resolved -notmatch '^([A-Za-z]):/(.*)$') {
        throw "Cannot convert path for Git Bash: $WindowsPath"
    }
    return "/$($Matches[1].ToLowerInvariant())/$($Matches[2])"
}

function Find-GnuMake {
    $command = Get-Command make.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $packageRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $candidate = Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter make.exe -ErrorAction SilentlyContinue |
        Where-Object FullName -Like '*ezwinports.make*' |
        Select-Object -First 1
    if ($candidate) {
        return $candidate.FullName
    }
    throw 'GNU Make 4.x was not found. Install it with: winget install --id ezwinports.make --exact --scope user'
}

& (Join-Path $PSScriptRoot 'bootstrap.ps1') -AndroidSdk $AndroidSdk
$config = Read-Properties -Path $ConfigPath
$resolvedSdk = if ($AndroidSdk) {
    (Resolve-Path -LiteralPath $AndroidSdk).Path
}
elseif ($env:ANDROID_SDK_ROOT) {
    (Resolve-Path -LiteralPath $env:ANDROID_SDK_ROOT).Path
}
elseif ($env:ANDROID_HOME) {
    (Resolve-Path -LiteralPath $env:ANDROID_HOME).Path
}
else {
    (Resolve-Path -LiteralPath 'C:\Android\Sdk').Path
}
$ndkPath = Join-Path $resolvedSdk "ndk\$($config['ffmpeg.ndkVersion'])"
$makePath = Find-GnuMake
if (!(Test-Path -LiteralPath $GitBashPath)) {
    throw "Git Bash was not found: $GitBashPath"
}

$nativeLibrariesPresent = $true
foreach ($abi in $SupportedAbis) {
    $abiLibraryPath = Join-Path $FfmpegPath "android-libs\$abi\libavcodec.a"
    if (!(Test-Path -LiteralPath $abiLibraryPath)) {
        $nativeLibrariesPresent = $false
        break
    }
}

if ($RebuildNative -or !$nativeLibrariesPresent) {
    $env:LM_FFMPEG_MODULE_PATH = Convert-ToMsysPath -WindowsPath (Join-Path $DecoderModulePath 'src\main')
    $env:LM_NDK_PATH = Convert-ToMsysPath -WindowsPath $ndkPath
    $env:LM_BUILD_SCRIPT = Convert-ToMsysPath -WindowsPath (Join-Path $DecoderModulePath 'src\main\jni\build_ffmpeg.sh')
    $env:LM_MAKE_DIR = Convert-ToMsysPath -WindowsPath (Split-Path -Parent $makePath)
    $env:LM_HOST_PLATFORM = $WindowsHostPlatform
    $env:LM_ANDROID_API = $config['ffmpeg.androidApi']
    $env:LM_DECODERS = $config['ffmpeg.decoders'].Replace(',', ' ')

    # Media3's official script uses FFmpeg static libraries and builds all supported Android ABIs.
    $bashCommand = @'
set -euo pipefail
export PATH="${LM_MAKE_DIR}:${PATH}"
bash "${LM_BUILD_SCRIPT}" \
  "${LM_FFMPEG_MODULE_PATH}" \
  "${LM_NDK_PATH}" \
  "${LM_HOST_PLATFORM}" \
  "${LM_ANDROID_API}" \
  ${LM_DECODERS}
'@
    & $GitBashPath -lc $bashCommand
    if ($LASTEXITCODE -ne 0) {
        throw 'FFmpeg native library build failed.'
    }
}
else {
    Write-Host 'Reusing previously built FFmpeg native libraries. Use -RebuildNative to rebuild them.'
}

$ffmpegConfig = Get-Content -Raw -LiteralPath (Join-Path $FfmpegPath 'config.h')
foreach ($disabledLicenseFeature in @('GPL', 'NONFREE', 'VERSION3')) {
    if ($ffmpegConfig -notmatch "(?m)^#define CONFIG_$disabledLicenseFeature 0$") {
        throw "Unsafe FFmpeg license configuration: CONFIG_$disabledLicenseFeature must be disabled."
    }
}
$ffmpegComponents = Get-Content -Raw -LiteralPath (Join-Path $FfmpegPath 'config_components.h')
foreach ($decoder in $config['ffmpeg.decoders'].Split(',')) {
    $decoderMacro = $decoder.ToUpperInvariant()
    if ($ffmpegComponents -notmatch "(?m)^#define CONFIG_${decoderMacro}_DECODER 1$") {
        throw "Required FFmpeg decoder is missing from the native build: $decoder"
    }
}
Write-Host 'Verified LGPL-only FFmpeg configuration and required decoders.'

$env:ANDROID_HOME = $resolvedSdk
$env:ANDROID_SDK_ROOT = $resolvedSdk
$gradleWrapper = Join-Path $Media3Path 'gradlew.bat'
Push-Location $Media3Path
try {
    & $gradleWrapper :lib-decoder-ffmpeg:assembleRelease --no-daemon
    if ($LASTEXITCODE -ne 0) {
        throw 'Media3 decoder AAR build failed.'
    }
}
finally {
    Pop-Location
}

$aarRelativePath = 'outputs\aar\lib-decoder-ffmpeg-release.aar'
$sourceAarCandidates = @(
    (Join-Path $DecoderModulePath "buildout\$aarRelativePath"),
    (Join-Path $DecoderModulePath "build\$aarRelativePath")
)
$sourceAar = $sourceAarCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (!$sourceAar) {
    throw "Expected AAR was not produced under the decoder module build directories."
}
New-Item -ItemType Directory -Force -Path $DistPath | Out-Null
$artifactName = "media3-decoder-ffmpeg-$($config['artifact.version']).aar"
$artifactPath = Join-Path $DistPath $artifactName
Copy-Item -LiteralPath $sourceAar -Destination $artifactPath -Force

$buildInfo = [ordered]@{
    artifact = $artifactName
    media3Ref = $config['media3.ref']
    media3Commit = $config['media3.commit']
    ffmpegRef = $config['ffmpeg.ref']
    ffmpegCommit = $config['ffmpeg.commit']
    ffmpegDecoders = $config['ffmpeg.decoders'].Split(',')
    artifactMinSdk = [int]$config['artifact.minSdk']
    ffmpegAndroidApi = [int]$config['ffmpeg.androidApi']
    ffmpegNdkVersion = $config['ffmpeg.ndkVersion']
    media3JniNdkVersion = $config['media3.jniNdkVersion']
    cmakeVersion = $config['android.cmakeVersion']
    license = 'Apache-2.0 AND LGPL-2.1-or-later'
}
$buildInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $DistPath 'build-info.json') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $FfmpegPath 'COPYING.LGPLv2.1') -Destination $DistPath -Force
Copy-Item -LiteralPath (Join-Path $FfmpegPath 'LICENSE.md') -Destination (Join-Path $DistPath 'FFMPEG-LICENSE.md') -Force
& (Join-Path $PSScriptRoot 'verify-aar.ps1') -AarPath $artifactPath
