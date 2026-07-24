#!/usr/bin/env pwsh
# Install the Bit compiler on Windows.
#
#   irm https://bit-lang.byteink.com/install.ps1 | iex
#
# Downloads the release zip named per dist/README.md's naming contract
# (bit-<version>-windows-<arch>.zip), verifies it against the release's
# SHA256SUMS, unpacks it under %LOCALAPPDATA%\bit and adds its bin\ to the
# user PATH. No wrapper script or env vars needed: bit.exe resolves
# stdlib/libbitrt.a relative to its own install location, same as the POSIX
# installers post-#1452 (dist/README.md, "Path resolution").
#
# NOTE: x86_64-windows and aarch64-windows are not published yet (#1103's
# runtime port + #358's release matrix are the remaining blockers) — until
# they are, this script downloads a real URL built from the naming contract
# and fails cleanly with a 404/"not found" rather than installing anything.
#
# All errors use `throw`, never `exit`: this script is meant to be piped
# through `iex`, and `exit` in that context would close the caller's whole
# PowerShell session instead of just stopping the install.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 can default to TLS 1.0, which GitHub's endpoints reject.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = "byteink/bit"
$BitRoot = if ($env:BITROOT) { $env:BITROOT } else { Join-Path $env:LOCALAPPDATA "bit" }

function Die {
    param([string]$Message)
    throw "install.ps1: $Message"
}

$osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$arch = switch ($osArch) {
    "X64" { "x86_64" }
    "Arm64" { "aarch64" }
    default { Die "unsupported architecture '$osArch' (supported: X64, Arm64)" }
}

if ($env:BIT_VERSION) {
    $version = $env:BIT_VERSION
} else {
    $latestUrl = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $latestUrl -Headers @{ "User-Agent" = "bit-install.ps1" }
    } catch {
        Die "could not resolve latest release from $latestUrl"
    }
    if (-not $release.tag_name) { Die "could not resolve latest release tag from $latestUrl" }
    $version = $release.tag_name.TrimStart("v")
}

$artifact = "bit-$version-windows-$arch.zip"
$baseUrl = "https://github.com/$Repo/releases/download/v$version"

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $workDir | Out-Null
try {
    $artifactPath = Join-Path $workDir $artifact
    $sumsPath = Join-Path $workDir "SHA256SUMS"

    Write-Host "install.ps1: downloading $artifact (bit $version)"
    try {
        Invoke-WebRequest -Uri "$baseUrl/$artifact" -OutFile $artifactPath -UseBasicParsing
    } catch {
        Die "download failed: $baseUrl/$artifact"
    }
    try {
        Invoke-WebRequest -Uri "$baseUrl/SHA256SUMS" -OutFile $sumsPath -UseBasicParsing
    } catch {
        Die "download failed: $baseUrl/SHA256SUMS"
    }

    $sumsLine = Select-String -Path $sumsPath -Pattern $artifact -SimpleMatch | Select-Object -First 1
    if (-not $sumsLine) { Die "$artifact has no entry in SHA256SUMS" }
    $expected = ($sumsLine.Line -split '\s+')[0].ToLowerInvariant()

    $actual = (Get-FileHash -Path $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Die "checksum mismatch for ${artifact}: expected $expected, got $actual"
    }

    $installName = "bit-$version-windows-$arch"
    $installDir = Join-Path $BitRoot $installName
    if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }
    New-Item -ItemType Directory -Path $BitRoot -Force | Out-Null
    Expand-Archive -Path $artifactPath -DestinationPath $BitRoot -Force

    $binDir = Join-Path $installDir "bin"
    if (-not (Test-Path (Join-Path $binDir "bit.exe"))) {
        Die "archive did not contain $installName\bin\bit.exe"
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathEntries = @()
    if ($userPath) { $pathEntries = $userPath -split ';' }
    if ($pathEntries -notcontains $binDir) {
        $newPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$env:Path;$binDir"
    }

    Write-Host "install.ps1: installed bit $version to $installDir"
    Write-Host "install.ps1: added $binDir to your user PATH (open a new shell to pick it up)"
} finally {
    Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
}
