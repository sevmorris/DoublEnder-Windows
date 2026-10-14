# Builds a Windows release folder and zip: DoublEnder.exe, its art and
# fonts, the Swift runtime DLLs it links against and, if given, ffmpeg.exe
# for AAC. Run from a shell where `swift` works (the Swift installer puts
# its runtime on PATH).
#
#   pwsh scripts/package-windows.ps1 [-Ffmpeg build\ffmpeg-windows\ffmpeg.exe]
param([string]$Ffmpeg = "")

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$version = (Select-String -Path Sources\DoublEnderCore\VersionFormatting.swift `
    -Pattern 'static let version = "(.*)"').Matches[0].Groups[1].Value
$name = "DoublEnder-$version-windows-x64"
$out = "dist\$name"

swift build -c release
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$bin = (swift build -c release --show-bin-path).Trim()

Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$out\licenses" | Out-Null
Copy-Item "$bin\DoublEnder.exe" $out
Copy-Item -Recurse Sources\DoublEnder\Resources "$out\Resources"
Copy-Item LICENSE "$out\licenses\DoublEnder-LICENSE.txt"
Copy-Item Vendor-licenses\* "$out\licenses\"
Copy-Item packaging\README-guest.txt "$out\README.txt"

# The Swift runtime: every DLL beside swiftCore.dll.
$swiftCore = (where.exe swiftCore.dll 2>$null | Select-Object -First 1)
if (-not $swiftCore) { throw "swiftCore.dll is not on PATH; is the Swift runtime installed?" }
Copy-Item (Join-Path (Split-Path $swiftCore) '*.dll') $out

# The Visual C++ runtime the Swift runtime needs. Most PCs have it; shipping
# it app-locally (permitted by its licence) covers the ones that don't.
foreach ($dll in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
    $path = Join-Path $env:SystemRoot "System32\$dll"
    if (Test-Path $path) { Copy-Item $path $out }
}

# AAC needs ffmpeg.exe beside DoublEnder.exe: the LGPL build that
# scripts/build-ffmpeg-windows.sh makes (CI builds it), passed as -Ffmpeg.
# Its licence and source note must sit beside it and ship with it. Nothing
# is taken from PATH, so a GPL or unknown build can't slip into a release.
# Without -Ffmpeg the app records WAV only.
if ($Ffmpeg) {
    $ffmpegDir = Split-Path -Parent (Resolve-Path $Ffmpeg)
    foreach ($note in 'ffmpeg-LICENSE.txt', 'ffmpeg-SOURCE.txt') {
        $notePath = Join-Path $ffmpegDir $note
        if (-not (Test-Path $notePath)) {
            throw "$note is missing beside $Ffmpeg; build ffmpeg.exe with scripts/build-ffmpeg-windows.sh"
        }
        Copy-Item $notePath "$out\licenses\"
    }
    Copy-Item $Ffmpeg "$out\ffmpeg.exe"
    Write-Host "Included ffmpeg: $Ffmpeg"
} else {
    Write-Host "No -Ffmpeg: this build records WAV only."
}

Compress-Archive -Force -Path $out -DestinationPath "dist\$name.zip"
Write-Host "dist\$name.zip"
