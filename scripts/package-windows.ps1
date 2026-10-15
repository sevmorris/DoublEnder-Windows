# Builds the Windows release: dist\DoublEnder-Setup.exe, the one file a
# guest downloads, and a symbols zip for reading crash dumps. It stages
# DoublEnder.exe, its art and fonts, the Swift runtime DLLs it links
# against and, if given, ffmpeg.exe for AAC in dist\DoublEnder-<version>-
# windows-x64, then compiles that folder into an installer with Inno Setup 6
# (packaging\DoublEnder.iss). Run from a shell where `swift` works (the
# Swift installer puts its runtime on PATH).
#
#   pwsh scripts/package-windows.ps1 [-Ffmpeg build\ffmpeg-windows\ffmpeg.exe]
param([string]$Ffmpeg = "")

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$version = (Select-String -Path Sources\DoublEnderCore\VersionFormatting.swift `
    -Pattern 'static let version = "(.*)"').Matches[0].Groups[1].Value
$name = "DoublEnder-$version-windows-x64"
$out = "dist\$name"

# A release build with CodeView debug info, so the linker writes
# DoublEnder.pdb beside the exe. The exe only records the PDB's name and
# GUID; the PDB stays out of the guests' zip and goes in its own
# symbols zip, with which a crash or hang dump from this exact build can
# be read down to function names (a dump without it shows only offsets).
$debugInfo = @('-Xswiftc', '-g', '-Xswiftc', '-debug-info-format=codeview', '-Xcc', '-g', '-Xlinker', '-debug')
swift build -c release @debugInfo
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$bin = (swift build -c release @debugInfo --show-bin-path).Trim()
$pdb = Join-Path $bin 'DoublEnder.pdb'
if (-not (Test-Path $pdb)) { throw "DoublEnder.pdb wasn't written: a dump from this build couldn't be read" }

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

# The installer. Swift can't yet link its runtime into the exe on Windows,
# and the exe would still need the Visual C++ runtime and ffmpeg.exe beside
# it, so guests get one Setup file instead of this folder.
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
              "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw "Inno Setup 6 isn't installed (winget install JRSoftware.InnoSetup)" }
# Windows wants a numeric file version: 2.6.0x is 2.6.0.
$fileVersion = $version -replace '[^0-9.].*$', ''
Remove-Item -Force dist\DoublEnder-Setup.exe -ErrorAction SilentlyContinue
& $iscc /Q "/DAppVersion=$version" "/DFileVersion=$fileVersion" "/DStageDir=$((Resolve-Path $out).Path)" `
    "/DOutputDir=$((Resolve-Path dist).Path)" packaging\DoublEnder.iss
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }

# The symbols, kept with the build they belong to. WinDbg matches the PDB
# to the exe by the GUID the linker recorded, and looks for it by its own
# name, so it stays DoublEnder.pdb inside the versioned zip.
$symbols = "dist\$name-symbols"
Remove-Item -Recurse -Force $symbols -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $symbols | Out-Null
Copy-Item $pdb $symbols
Compress-Archive -Force -Path "$symbols\DoublEnder.pdb" -DestinationPath "dist\$name-symbols.zip"
Write-Host "dist\$name-symbols.zip"
Write-Host "dist\DoublEnder-Setup.exe"
