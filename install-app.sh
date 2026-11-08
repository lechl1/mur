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

# Signature. mur reads other apps' windows through the Accessibility API,
# and macOS refuses to hand out that permission to an unsigned bundle.
#
# WHICH identity matters more than it looks. An ad-hoc signature (`-`) has
# no stable designated requirement, so TCC remembers the grant by the
# binary's cdhash — which changes on EVERY build. The result is that each
# `just install` silently revokes Accessibility: mur comes back up seeing
# zero windows, with hotkeys that register and then do nothing.
#
# The fix is a certificate issued by the homelab code-signing CA, the one
# slipway signs the published cask with (slipway/src/desktop.rs). The
# signature then carries the cask's own designated requirement,
#   identifier "com.mur.MurApp" and certificate root = H"<CA root sha1>"
# so TCC sees a local build and a depot release as the SAME app: one
# Accessibility grant covers both, through rebuilds and `depot sync` alike.
# The identity is `mur-dev` in the login keychain (a leaf the CA on n5
# issued for this Mac); MUR_CODESIGN_IDENTITY overrides it. The CA root is
# where ansible's codesign-trust.yml keeps it (MUR_CODESIGN_ROOT overrides).
identity="${MUR_CODESIGN_IDENTITY:-}"
if [ -z "$identity" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"mur-dev"'; then
    identity="mur-dev"
fi
root_pem="${MUR_CODESIGN_ROOT:-$HOME/.local/share/homelab/codesign-root.pem}"
bundle_id="$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist")"
requirement=()
if [ -n "$identity" ] && [ "$identity" != - ] && test -f "$root_pem"; then
    root_sha1="$(openssl x509 -in "$root_pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
    requirement=(-r="designated => identifier \"$bundle_id\" and certificate root = H\"$root_sha1\"")
fi
# Inside-out, not --deep: the CLI is signed first, then the bundle seals it.
test -x "$DEST/Contents/MacOS/mur" && codesign --force --sign "${identity:--}" "$DEST/Contents/MacOS/mur"
codesign --force --sign "${identity:--}" ${requirement[@]+"${requirement[@]}"} "$DEST"
if [ -z "$identity" ] || [ "$identity" = - ]; then
    echo "ℹ️  Signed ad-hoc: this build must be re-granted Accessibility."
    echo "   A 'mur-dev' identity from the homelab CA would make the grant stick (see CLAUDE.md)."
elif ! codesign -v -R="identifier \"$bundle_id\" and anchor trusted" "$DEST" 2> /dev/null; then
    echo "⚠️  $identity does not chain to a trusted root: run ansible's \`just codesign-trust\`." >&2
fi

# Tell LaunchServices about the bundle right away, so Spotlight and
# Finder see it (and pick up the new icon) without waiting for a rescan.
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
test -x "$lsregister" && "$lsregister" -f "$DEST" > /dev/null 2>&1 || true

echo "📦 Installed $DEST"
