#!/usr/bin/env bash
# Builds a self-contained Linux release: one statically linked binary (no
# Swift runtime needed on the guest's machine) plus its art and fonts,
# packed as dist/DoublEnder-<version>-linux-<arch>.tar.gz.
#
# The binary needs the glibc of the machine it was built on or newer, so
# build releases on an older distribution (the CI uses Ubuntu 24.04).
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/DoublEnderCore/VersionFormatting.swift)
arch=$(uname -m)
name="DoublEnder-${version}-linux-${arch}"

# Static linking needs SwiftPM's native build system: Swift 6.4's new
# default one doesn't link Foundation statically yet. Older SwiftPMs only
# have the native one and no flag to choose it.
build_system=()
if swift build --help 2>/dev/null | grep -q -- '--build-system'; then
    build_system=(--build-system native)
fi
swift build -c release --static-swift-stdlib "${build_system[@]}"
bin=$(swift build -c release "${build_system[@]}" --show-bin-path)

rm -rf "dist/$name"
mkdir -p "dist/$name/licenses"
cp "$bin/DoublEnder" "dist/$name/"
strip "dist/$name/DoublEnder"
cp -r Sources/DoublEnder/Resources "dist/$name/Resources"
cp LICENSE "dist/$name/licenses/DoublEnder-LICENSE.txt"
cp Vendor-licenses/* "dist/$name/licenses/"
cp packaging/README-guest.txt "dist/$name/README.txt"
cp packaging/install.sh "dist/$name/install.sh"
chmod +x "dist/$name/install.sh"

tar -C dist -czf "dist/$name.tar.gz" "$name"
echo "dist/$name.tar.gz"
