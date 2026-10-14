# Builds a Windows release folder and zip: DoublEnder.exe, its art and
# fonts, the Swift runtime DLLs it links against and, if found, ffmpeg.exe
# for AAC. Run from a shell where `swift` works (the Swift installer puts
# its runtime on PATH).
#
#   pwsh scripts/package-windows.ps1 [-Ffmpeg C:\path\to\ffmpeg.exe]
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
Copy-Item ..\LICENSE "$out\licenses\DoublEnder-LICENSE.txt"
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

# AAC needs ffmpeg.exe beside DoublEnder.exe. Ship an LGPL build and its
# licence; without it the app records WAV only.
if (-not $Ffmpeg) { $Ffmpeg = (where.exe ffmpeg.exe 2>$null | Select-Object -First 1) }
if ($Ffmpeg) {
    Copy-Item $Ffmpeg "$out\ffmpeg.exe"
    Write-Host "Included ffmpeg: $Ffmpeg (add its licence to $out\licenses)"
} else {
    Write-Host "No ffmpeg.exe found: this build records WAV only."
}

Compress-Archive -Force -Path $out -DestinationPath "dist\$name.zip"
Write-Host "dist\$name.zip"
