[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $RepositoryRoot 'config\dependencies.properties'
$Media3Path = Join-Path $RepositoryRoot '.deps\media3'
$FfmpegPath = Join-Path $Media3Path 'libraries\decoder_ffmpeg\src\main\jni\ffmpeg'
$BuildOutputPath = Join-Path $RepositoryRoot 'dist'
$ReleasePath = Join-Path $RepositoryRoot 'release'

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

if (!(Test-Path -LiteralPath (Join-Path $FfmpegPath '.git'))) {
    throw 'Upstream sources are missing. Run scripts/bootstrap.ps1 first.'
}
if (!(Test-Path -LiteralPath $BuildOutputPath)) {
    throw 'Build output is missing. Run scripts/build-aar.ps1 first.'
}
New-Item -ItemType Directory -Force -Path $ReleasePath | Out-Null
$config = Read-Properties -Path $ConfigPath
$shortFfmpegCommit = $config['ffmpeg.commit'].Substring(0, 12)
$shortMedia3Commit = $config['media3.commit'].Substring(0, 12)
$artifactName = "media3-decoder-ffmpeg-$($config['artifact.version']).aar"
$ffmpegArchive = Join-Path $ReleasePath "ffmpeg-source-$shortFfmpegCommit.tar.gz"
$media3Archive = Join-Path $ReleasePath "media3-decoder-ffmpeg-source-$shortMedia3Commit.tar.gz"

Copy-Item -LiteralPath (Join-Path $BuildOutputPath $artifactName) -Destination $ReleasePath -Force
Copy-Item -LiteralPath (Join-Path $BuildOutputPath 'build-info.json') -Destination $ReleasePath -Force
Copy-Item -LiteralPath (Join-Path $FfmpegPath 'COPYING.LGPLv2.1') -Destination $ReleasePath -Force
Copy-Item -LiteralPath (Join-Path $FfmpegPath 'LICENSE.md') -Destination (Join-Path $ReleasePath 'FFMPEG-LICENSE.md') -Force

# Source archives are generated from the exact checked-out commits used by the binary build.
& git -C $FfmpegPath archive --format=tar.gz --prefix="ffmpeg-$shortFfmpegCommit/" -o $ffmpegArchive HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to create the FFmpeg source archive.'
}
& git -C $Media3Path archive --format=tar.gz --prefix="media3-$shortMedia3Commit/" -o $media3Archive HEAD libraries/decoder_ffmpeg
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to create the Media3 decoder source archive.'
}

$checksumFileName = 'SHA256SUMS.txt'
$releaseFiles = Get-ChildItem -LiteralPath $ReleasePath -File |
    Where-Object Name -Ne $checksumFileName
$checksumLines = foreach ($file in $releaseFiles) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    "$hash  $($file.Name)"
}
$checksumLines | Set-Content -LiteralPath (Join-Path $ReleasePath $checksumFileName) -Encoding ASCII
Write-Host "Release bundle prepared under $ReleasePath"
