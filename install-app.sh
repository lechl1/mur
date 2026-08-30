#!/bin/bash
# mur — install the built app bundle into /Applications so mur can be
# launched from Finder / Spotlight / the Dock like any other Mac app.
#
#   bash install-app.sh                     # install to /Applications/Mur.app
#   MUR_INSTALL_DIR=~/Applications bash install-app.sh
#   bash install-app.sh --uninstall
#
# Normally you don't call this directly — `just install` builds first and
# then runs this, symlinks the CLI, and restarts the daemon.
#
# The bundle is assembled by hand from the SwiftPM build products rather
# than by xcodebuild: build-release.sh needs a codesign certificate, a
# universal build and a clean worktree, none of which a local install
# wants. Everything the app needs at runtime is the executable itself
# (the Info.plist keys below plus an ad-hoc signature), so a hand-rolled
# bundle behaves identically to the Xcode one.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="$PWD"

APP_NAME="Mur"
BUNDLE_ID="com.mur.MurApp"
INSTALL_DIR="${MUR_INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/$APP_NAME.app"

SRC_APP="$REPO/.debug/MurApp.app"
SRC_BIN="$SRC_APP/Contents/MacOS/MurApp"
SRC_CLI="$REPO/.debug/mur"

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -rf "$DEST"
    echo "🗑  Removed $DEST"
    exit 0
fi

if ! test -x "$SRC_BIN"; then
    echo "error: $SRC_BIN not found — run 'just build' (or bash build-debug.sh) first" >&2
    exit 1
fi

##################
### ASSEMBLE   ###
##################

# Replace the bundle wholesale: a stale Assets.car or an old executable
# left behind by a previous layout would be signed right back in.
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"

cp "$SRC_BIN" "$DEST/Contents/MacOS/MurApp"
# Ship the CLI inside the bundle so /usr/local/bin/mur doesn't point back
# into the source tree — an installed app shouldn't break when the repo
# moves.
test -x "$SRC_CLI" && cp "$SRC_CLI" "$DEST/Contents/MacOS/mur"

printf 'APPL????' > "$DEST/Contents/PkgInfo"

# App icon. Built with sips + iconutil rather than `actool` on purpose:
# actool is an Xcode IDE plugin host and dies with "A required plugin
# failed to load" on machines that never ran `xcodebuild -runFirstLaunch`,
# whereas sips/iconutil are plain /usr/bin tools. A missing icon is not
# fatal — the app just gets the generic one.
icon_key=""
icon_src="$REPO/resources/Assets.xcassets/AppIcon.appiconset/icon.png"
if test -f "$icon_src" && command -v iconutil > /dev/null 2>&1; then
    iconset="$(mktemp -d -t mur-iconset.XXXXXX)/AppIcon.iconset"
    mkdir -p "$iconset"
    ok=1
    for size in 16 32 128 256 512; do
        sips -z $size $size          "$icon_src" --out "$iconset/icon_${size}x${size}.png"    > /dev/null 2>&1 || ok=0
        sips -z $((size*2)) $((size*2)) "$icon_src" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null 2>&1 || ok=0
    done
    if test $ok == 1 && iconutil -c icns "$iconset" -o "$DEST/Contents/Resources/AppIcon.icns" > /dev/null 2>&1; then
        icon_key='    <key>CFBundleIconFile</key>          <string>AppIcon</string>'
    fi
    rm -rf "$(dirname "$iconset")"
fi

version="$(sed -n 's/.*aeroSpaceAppVersion = "\(.*\)".*/\1/p' "$REPO/Sources/Common/versionGenerated.swift")"
version="${version:-0.0.0-SNAPSHOT}"

cat > "$DEST/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>MurApp</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>         <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>  <string>$version</string>
    <key>CFBundleVersion</key>             <string>$version</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
$icon_key
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
EOF

# Ad-hoc signature. mur reads other apps' windows through the
# Accessibility API, and macOS refuses to hand out that permission to an
# unsigned bundle.
codesign --force --deep --sign - "$DEST" > /dev/null 2>&1 || true

# Tell LaunchServices about the bundle right away, so Spotlight and
# Finder see it (and pick up the new icon) without waiting for a rescan.
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
test -x "$lsregister" && "$lsregister" -f "$DEST" > /dev/null 2>&1 || true

echo "📦 Installed $DEST"
