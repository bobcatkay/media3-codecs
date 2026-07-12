[CmdletBinding()]
param(
    [string]$AndroidSdk
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $RepositoryRoot 'config\dependencies.properties'
$DependenciesRoot = Join-Path $RepositoryRoot '.deps'
$Media3Path = Join-Path $DependenciesRoot 'media3'
$FfmpegPath = Join-Path $Media3Path 'libraries\decoder_ffmpeg\src\main\jni\ffmpeg'

function Read-Properties {
    param([Parameter(Mandatory)][string]$Path)

    $properties = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (!$trimmed -or $trimmed.StartsWith('#')) {
            continue
        }
        $parts = $trimmed.Split('=', 2)
        if ($parts.Count -ne 2) {
            throw "Invalid dependency property: $line"
        }
        $properties[$parts[0].Trim()] = $parts[1].Trim()
    }
    return $properties
}

function Resolve-AndroidSdk {
    param([string]$RequestedPath)

    $candidates = @(
        $RequestedPath,
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        'C:\Android\Sdk',
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'platform-tools')) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw 'Android SDK was not found. Pass -AndroidSdk or set ANDROID_SDK_ROOT.'
}

function Sync-UpstreamRepository {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$Destination
    )

    if (!(Test-Path -LiteralPath (Join-Path $Destination '.git'))) {
        Write-Host "Cloning $Name from $Repository"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        & git clone --filter=blob:none --no-checkout $Repository $Destination
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone $Name."
        }
    }

    Write-Host "Checking out $Name commit $Commit"
    & git -C $Destination fetch --depth 1 origin $Ref
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch $Name ref $Ref."
    }
    & git -C $Destination checkout --detach $Commit
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to check out $Name commit $Commit."
    }

    $actualCommit = (& git -C $Destination rev-parse HEAD).Trim()
    if ($actualCommit -ne $Commit) {
        throw "$Name checkout mismatch: expected $Commit, got $actualCommit."
    }
    if (& git -C $Destination status --porcelain) {
        throw "$Name source tree contains local changes."
    }
}

$config = Read-Properties -Path $ConfigPath
$resolvedSdk = Resolve-AndroidSdk -RequestedPath $AndroidSdk
$ffmpegNdkPath = Join-Path $resolvedSdk "ndk\$($config['ffmpeg.ndkVersion'])"
$jniNdkPath = Join-Path $resolvedSdk "ndk\$($config['media3.jniNdkVersion'])"
$cmakePath = Join-Path $resolvedSdk "cmake\$($config['android.cmakeVersion'])"
if (!(Test-Path -LiteralPath $ffmpegNdkPath)) {
    throw "Required FFmpeg Android NDK is missing: $ffmpegNdkPath"
}
if (!(Test-Path -LiteralPath $jniNdkPath)) {
    throw "Required Media3 JNI Android NDK is missing: $jniNdkPath"
}
if (!(Test-Path -LiteralPath $cmakePath)) {
    throw "Required Android CMake is missing: $cmakePath"
}

Sync-UpstreamRepository `
    -Name 'Media3' `
    -Repository $config['media3.repository'] `
    -Ref $config['media3.ref'] `
    -Commit $config['media3.commit'] `
    -Destination $Media3Path

Sync-UpstreamRepository `
    -Name 'FFmpeg' `
    -Repository $config['ffmpeg.repository'] `
    -Ref $config['ffmpeg.ref'] `
    -Commit $config['ffmpeg.commit'] `
    -Destination $FfmpegPath

# Gradle needs a machine-local SDK path, but it must never be committed.
$escapedSdk = $resolvedSdk.Replace('\', '\\').Replace(':', '\:')
$localPropertiesPath = Join-Path $Media3Path 'local.properties'
Set-Content -LiteralPath $localPropertiesPath -Value "sdk.dir=$escapedSdk" -Encoding ASCII

Write-Host "Media3: $($config['media3.commit'])"
Write-Host "FFmpeg: $($config['ffmpeg.commit'])"
Write-Host "Android SDK: $resolvedSdk"
Write-Host 'Bootstrap completed.'
