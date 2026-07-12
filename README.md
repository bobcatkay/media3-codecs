# media3-codecs

Unofficial, reproducible Android AAR builds of Media3 decoder extensions.
The first artifact is Media3's FFmpeg audio decoder with AC-3, E-AC-3,
TrueHD, and DTS/DTS-HD decoding enabled.

This repository contains only build orchestration and compliance metadata.
Media3 and FFmpeg are fetched from their official GitHub repositories at exact
commits recorded in [`config/dependencies.properties`](config/dependencies.properties).

## Prerequisites

- Windows 11
- Git for Windows
- PowerShell 7
- JDK 17
- Android SDK at `C:\Android\Sdk`, or pass `-AndroidSdk`
- Android NDK and CMake versions listed in `config/dependencies.properties`
- GNU Make 4.x

Install GNU Make for the current Windows user if needed:

```powershell
winget install --id ezwinports.make --exact --scope user
```

## Fetch sources

```powershell
.\scripts\bootstrap.ps1
```

Fetched sources live under `.deps/` and are intentionally ignored. The script
checks out detached, exact commits and rejects modified upstream trees.

## Build and verify the AAR

```powershell
.\scripts\build-aar.ps1
```

The output is written to `dist/`. The build produces all four Media3-supported
Android ABIs and verifies that each `libffmpegJNI.so` is present in the AAR.
Previously built native libraries are reused; pass `-RebuildNative` to force a
clean FFmpeg rebuild.

Prepare the upload-ready `release/` directory with the AAR, matching source
archives, licenses, build information, and checksums:

```powershell
.\scripts\package-release.ps1
```

## Consume from an Android app

Use official Media3 Maven artifacts for core playback and add the generated
FFmpeg decoder AAR separately:

```groovy
implementation 'androidx.media3:media3-exoplayer:1.10.1'
implementation 'androidx.media3:media3-ui:1.10.1'
implementation files('libs/media3-decoder-ffmpeg-1.10.1-ffmpeg6.0-r1.aar')
```

Enable extension renderers with `DefaultRenderersFactory`. Use
`EXTENSION_RENDERER_MODE_ON` for fallback-only decoding or
`EXTENSION_RENDERER_MODE_PREFER` to prefer FFmpeg.

## Licensing

Build scripts and original repository content are Apache-2.0. Media3 is
Apache-2.0. FFmpeg remains LGPL-2.1-or-later, so generated AARs are not
Apache-only. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
