[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AarPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RequiredAbis = @('armeabi-v7a', 'arm64-v8a', 'x86', 'x86_64')
$resolvedAar = (Resolve-Path -LiteralPath $AarPath).Path
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedAar)
try {
    $entryNames = @($archive.Entries | ForEach-Object FullName)
    if ('classes.jar' -notin $entryNames) {
        throw 'AAR does not contain classes.jar.'
    }
    foreach ($abi in $RequiredAbis) {
        $nativeLibrary = "jni/$abi/libffmpegJNI.so"
        if ($nativeLibrary -notin $entryNames) {
            throw "AAR does not contain $nativeLibrary."
        }
    }
}
finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedAar).Hash.ToLowerInvariant()
Write-Host "Verified AAR: $resolvedAar"
Write-Host "SHA-256: $hash"
