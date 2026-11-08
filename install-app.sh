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
# (resources/Info.plist plus the signature), so a hand-rolled bundle
# behaves identically to the Xcode one. This is the only bundle a local
# build makes: Mur.app, `com.mur.MurApp`, the cask's own identity.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="$PWD"

APP_NAME="Mur"
INSTALL_DIR="${MUR_INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/$APP_NAME.app"

SRC_BIN="$REPO/.debug/MurApp"
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

# The bundle's manifest and icon are checked in (resources/Info.plist,
# resources/AppIcon.icns): the same files slipway bundles into the cask, so a
# local install and a published one are the same app. Only the version is
# filled in here. To change the icon, rebuild AppIcon.icns from
# Assets.xcassets/AppIcon.appiconset/icon.png with sips + iconutil (not actool,
# an Xcode IDE plugin host that dies on machines that never ran
# `xcodebuild -runFirstLaunch`).
cp "$REPO/resources/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"

version="$(sed -n 's/.*aeroSpaceAppVersion = "\(.*\)".*/\1/p' "$REPO/Sources/Common/versionGenerated.swift")"
version="${version:-0.0.0-SNAPSHOT}"

cp "$REPO/resources/Info.plist" "$DEST/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$DEST/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$DEST/Contents/Info.plist"

# Signed like the cask, so a local install keeps the grant a release has
# (and the other way round): see script/sign-app.sh.
bash "$REPO/script/sign-app.sh" "$DEST"

# Tell LaunchServices about the bundle right away, so Spotlight and
# Finder see it (and pick up the new icon) without waiting for a rescan.
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
test -x "$lsregister" && "$lsregister" -f "$DEST" > /dev/null 2>&1 || true

echo "📦 Installed $DEST"
