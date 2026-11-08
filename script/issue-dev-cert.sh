#!/bin/bash
# Issue (or renew) `mur-dev`, the identity a local build of Mur.app is signed
# with (script/sign-app.sh), from the homelab code-signing CA on n5 — the CA
# slipway signs the published cask with. A bundle signed by it carries the
# cask's designated requirement, so a local build and a depot release share
# one Accessibility grant.
#
#   bash script/issue-dev-cert.sh            # issue unless good for 30 more days
#   bash script/issue-dev-cert.sh --force    # issue a new one regardless
#
# The key is made here and never leaves this Mac: n5 only signs its CSR, as
# the `slipway` account (sudo there; the password comes from the askpass
# dialog, never a terminal). Needs this Mac to trust the CA for code signing:
# ansible's `just codesign-trust`.
set -euo pipefail

name="mur-dev"
ca_dir="/home/slipway/.local/share/slipway/codesign"
host="${MUR_CA_HOST:-n5}"
keychain="$HOME/Library/Keychains/login.keychain-db"

# Good for 30 more days already: nothing to do.
if [ "${1:-}" != --force ]; then
    if security find-certificate -c "$name" -p "$keychain" 2> /dev/null \
        | openssl x509 -noout -checkend 2592000 > /dev/null 2>&1 \
        && security find-identity -v -p codesigning | grep -q "\"$name\""; then
        echo "✅ $name is valid for 30 more days"
        exit 0
    fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077
cd "$work"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out key.pem 2> /dev/null
openssl req -new -key key.pem -subj "/CN=$name" -out csr.pem
csr="$(base64 < csr.pem | tr -d '\n')"

# The same extensions slipway-codesign-issue gives slipway's own leaf
# (ansible/roles/slipway/tasks/codesign.yml).
remote="set -euo pipefail
t=\$(mktemp -d); trap 'rm -rf \$t' EXIT; chmod 755 \$t
echo $csr | base64 -d > \$t/csr.pem
printf '%s\n' basicConstraints=critical,CA:FALSE keyUsage=critical,digitalSignature \
  extendedKeyUsage=codeSigning subjectKeyIdentifier=hash authorityKeyIdentifier=keyid > \$t/ext
chmod 644 \$t/*
sudo -S -p '' -u slipway bash -c 'cd $ca_dir && openssl x509 -req -in \$1/csr.pem -CA root.pem -CAkey ca-key.pem -CAcreateserial -days 825 -sha256 -extfile \$1/ext' _ \$t"

askpass="${SUDO_ASKPASS:-$HOME/.local/bin/askpass}"
pw="$("$askpass" "sudo password on $host (to sign mur's local code-signing certificate)")"
printf '%s\n' "$pw" | ssh -o BatchMode=yes "$host" "$remote" > cert.pem
unset pw
ssh -o BatchMode=yes "$host" "cat /home/slipway/.local/share/slipway/codesign-root.pem" > root.pem
openssl verify -CAfile root.pem cert.pem > /dev/null

# Replace the old identity (certificate and key) with the new one.
while security find-certificate -c "$name" "$keychain" > /dev/null 2>&1; do
    security delete-identity -c "$name" "$keychain" > /dev/null 2>&1 \
        || security delete-certificate -c "$name" "$keychain" > /dev/null
done
p="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -certfile root.pem -name "$name" -passout "pass:$p" -out id.p12
security import id.p12 -k "$keychain" -P "$p" -T /usr/bin/codesign > /dev/null
unset p

security find-identity -v -p codesigning | grep -q "\"$name\"" \
    || { echo "error: $name was imported but is not a valid code-signing identity: does this Mac trust the CA? (ansible: just codesign-trust)" >&2; exit 1; }
echo "✅ issued $name, $(openssl x509 -in cert.pem -noout -enddate)"
