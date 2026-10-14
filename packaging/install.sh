#!/usr/bin/env bash
# Installs DoublEnder for this user: the app in ~/.local/share/DoublEnder and
# a launcher in the applications menu (which also gives the window its icon
# in the dock). Run it from the unpacked folder; run it again to update.
#
#   ./install.sh               install or update
#   ./install.sh --uninstall   remove the app and the launcher
#
# Recordings, settings and logs are never touched.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
app="$data/DoublEnder"
launcher="$data/applications/doublender.desktop"

refresh_menu() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$data/applications" >/dev/null 2>&1 || true
    fi
}

if [ "${1:-}" = "--uninstall" ]; then
    rm -rf "$app" "$app.new" "$app.old"
    rm -f "$launcher"
    refresh_menu
    echo "DoublEnder has been removed. Your recordings and settings are untouched."
    exit 0
fi

if [ ! -x "$here/DoublEnder" ] || [ ! -d "$here/Resources" ]; then
    echo "Run this from the unpacked DoublEnder folder, beside the DoublEnder program." >&2
    exit 1
fi

# Copied whole, then swapped in by rename, so a copy that is running keeps
# its files and an interrupted install leaves the old one in place.
if [ "$here" != "$app" ]; then
    mkdir -p "$data"
    rm -rf "$app.new" "$app.old"
    mkdir "$app.new"
    cp -R "$here/DoublEnder" "$here/Resources" "$app.new/"
    [ -d "$here/licenses" ] && cp -R "$here/licenses" "$app.new/"
    [ -f "$here/README.txt" ] && cp "$here/README.txt" "$app.new/"
    if [ -d "$app" ]; then mv "$app" "$app.old"; fi
    mv "$app.new" "$app"
    rm -rf "$app.old"
fi

# Desktop Entry values: Exec quotes the path and backslash-escapes " ` $ \,
# doubles %, then every value escapes \ once more.
entry_string() { local s=$1; printf '%s' "${s//\\/\\\\}"; }
exec_quoted() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\`/\\\`}; s=${s//\$/\\\$}; s=${s//%/%%}
    printf '"%s"' "$(entry_string "$s")"
}

mkdir -p "$data/applications"
cat > "$launcher.tmp" <<EOF
[Desktop Entry]
Type=Application
Name=DoublEnder
GenericName=Audio Recorder
Comment=Record your side of a remote conversation
Exec=$(exec_quoted "$app/DoublEnder")
Icon=$(entry_string "$app/Resources/Images/app_icon.png")
Terminal=false
Categories=AudioVideo;Audio;Recorder;
StartupWMClass=DoublEnder
EOF
mv "$launcher.tmp" "$launcher"
refresh_menu

echo "DoublEnder is installed: start it from your applications menu."
echo "This folder is no longer needed."
