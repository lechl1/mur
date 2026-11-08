#!/bin/bash
# Sign a Mur.app bundle the way slipway signs the published cask, so TCC
# sees every build — local or from depot — as the same app.
#
#   bash script/sign-app.sh <path/to/Mur.app>
#
# mur reads other apps' windows through the Accessibility API, and the
# grant is remembered by the bundle's designated requirement. An ad-hoc
# signature (`-`) has none that lasts: TCC falls back to the cdhash, which
# changes on EVERY build, so each install silently revokes Accessibility —
# mur comes back up seeing zero windows, with hotkeys that do nothing.
#
# So the bundle is signed with `mur-dev`, a leaf issued by the homelab
# code-signing CA (script/issue-dev-cert.sh), and given the cask's own
# requirement (slipway/src/desktop.rs):
#   identifier "com.mur.MurApp" and certificate root = H"<CA root sha1>"
# One Accessibility grant then covers local builds and `depot sync` alike.
# MUR_CODESIGN_IDENTITY overrides the identity (`-` signs ad hoc), and
# MUR_CODESIGN_ROOT the CA root (where ansible's codesign-trust.yml puts it).
set -euo pipefail

app="${1:?usage: sign-app.sh <bundle.app>}"

identity="${MUR_CODESIGN_IDENTITY:-}"
if [ -z "$identity" ] && security find-identity -v -p codesigning 2> /dev/null | grep -q '"mur-dev"'; then
    identity="mur-dev"
fi
identity="${identity:--}"
root_pem="${MUR_CODESIGN_ROOT:-$HOME/.local/share/homelab/codesign-root.pem}"
bundle_id="$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")"

requirement=()
if [ "$identity" != - ] && test -f "$root_pem"; then
    root_sha1="$(openssl x509 -in "$root_pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
    requirement=(-r="designated => identifier \"$bundle_id\" and certificate root = H\"$root_sha1\"")
fi

# Inside-out, not --deep: every executable in Contents/MacOS first, then the
# bundle, which seals them.
for exe in "$app"/Contents/MacOS/*; do
    [ "$(basename "$exe")" = "$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")" ] && continue
    codesign --force --sign "$identity" "$exe" 2> /dev/null
done
codesign --force --sign "$identity" ${requirement[@]+"${requirement[@]}"} "$app" 2> /dev/null

if [ "$identity" = - ]; then
    echo "ℹ️  Signed $app ad hoc: it must be granted Accessibility again."
    echo "   bash script/issue-dev-cert.sh makes the grant stick." >&2
elif ! codesign -v -R="identifier \"$bundle_id\" and anchor trusted" "$app" 2> /dev/null; then
    echo "⚠️  $identity does not chain to a trusted root: run ansible's \`just codesign-trust\`." >&2
elif [ "$identity" = mur-dev ] && ! security find-certificate -c mur-dev -p 2> /dev/null | openssl x509 -noout -checkend 2592000 > /dev/null 2>&1; then
    echo "⚠️  mur-dev expires within 30 days: renew it with bash script/issue-dev-cert.sh" >&2
fi
