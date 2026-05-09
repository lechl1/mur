#!/usr/bin/env bash
# bootstrap.sh — install build dependencies for mur.
#
# Idempotent: safe to re-run. Does NOT touch your existing Xcode install.
#
# What it installs:
#   • Homebrew                (if missing)
#   • Swift 6.2 toolchain     (.pkg from swift.org → ~/Library/Developer/Toolchains/)
#   • xcbeautify              (prettier xcodebuild output — optional)
#   • bundler                 (Ruby gem; only needed for `build-release.sh` docs)
#
# We do NOT use swiftly: version 1.1.1 has a malloc abort
# ("freed pointer was not the last allocation") on macOS 14, so any
# subcommand crashes. Direct toolchain install bypasses it.
#
# What it does NOT do:
#   • Touch your system Xcode. Swift 6.2 lives in ~/.local/share/swiftly/.
#   • Install a codesign cert. The release build wants
#     `aerospace-codesign-certificate`; create one in Keychain Access if you
#     plan to run ./build-release.sh.
#   • Upgrade Xcode. The release pipeline shells out to xcodebuild which
#     uses Xcode's bundled toolchain, not swiftly's — so a full
#     ./install-from-sources.sh requires Xcode 16.4+ or 17+ regardless of
#     anything this script does. ./build-debug.sh works on any Xcode
#     because it goes through swiftly directly.
#
# Usage:
#   ./bootstrap.sh                 # install everything above
#   ./bootstrap.sh --minimal       # only Homebrew + swiftly + Swift 6.2
#   ./bootstrap.sh --check         # report what's missing, install nothing
#
# After this completes, run:
#   ./build-debug.sh        # compile (~1-2 min, single-arch)
#   ./swift-test.sh         # run unit tests including new GridLayoutTest
#   .debug/aerospace --help # try the freshly built CLI

set -euo pipefail

mode="all"
while test $# -gt 0; do
    case "$1" in
        --minimal) mode="minimal"; shift ;;
        --check)   mode="check"; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

REQUIRED_SWIFT="6.2"
SWIFT_TOOLCHAIN_NAME="swift-${REQUIRED_SWIFT}-RELEASE"
SWIFT_PKG_URL="https://download.swift.org/swift-${REQUIRED_SWIFT}-release/xcode/${SWIFT_TOOLCHAIN_NAME}/${SWIFT_TOOLCHAIN_NAME}-osx.pkg"
SWIFT_TOOLCHAIN_DIR="$HOME/Library/Developer/Toolchains/${SWIFT_TOOLCHAIN_NAME}.xctoolchain"
MUR_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_ENV_FILE="$MUR_DIR/.swift-env.sh"
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
say()  { printf "${GREEN}==>${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!! ${RESET} %s\n" "$*" >&2; }
fail() { printf "${RED}xx ${RESET} %s\n" "$*" >&2; exit 1; }

# --- Sanity --------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "mur builds on macOS only. Detected: $(uname -s)"
fi

if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    fail "Xcode Command Line Tools missing. Run: xcode-select --install"
fi

# --- Homebrew ------------------------------------------------------------
need_brew=0
if ! command -v brew >/dev/null 2>&1; then need_brew=1; fi

# --- Swift 6.2 toolchain (direct .pkg, no swiftly) ----------------------
need_swift=1
if [[ -x "$SWIFT_TOOLCHAIN_DIR/usr/bin/swift" ]]; then
    installed_ver="$("$SWIFT_TOOLCHAIN_DIR/usr/bin/swift" --version 2>&1 | head -1)"
    if echo "$installed_ver" | grep -q "Swift version $REQUIRED_SWIFT"; then
        need_swift=0
    fi
fi

# --- xcbeautify, bundler (optional) -------------------------------------
need_xcbeautify=0
if ! command -v xcbeautify >/dev/null 2>&1; then need_xcbeautify=1; fi
need_bundler=0
if ! command -v bundle >/dev/null 2>&1; then need_bundler=1; fi

# --- Report --------------------------------------------------------------
echo "Dependency check:"
printf "  Homebrew      : %s\n" "$([[ $need_brew      -eq 0 ]] && echo "OK" || echo "MISSING")"
printf "  Swift %-7s : %s\n" "$REQUIRED_SWIFT" "$([[ $need_swift -eq 0 ]] && echo "OK ($SWIFT_TOOLCHAIN_DIR)" || echo "MISSING")"
printf "  xcbeautify    : %s\n" "$([[ $need_xcbeautify -eq 0 ]] && echo "OK" || echo "missing (optional)")"
printf "  bundler       : %s\n" "$([[ $need_bundler   -eq 0 ]] && echo "OK" || echo "missing (optional, release-only)")"
echo

if [[ "$mode" == "check" ]]; then
    if [[ $need_brew -eq 0 && $need_swift -eq 0 ]]; then
        say "All required deps present. Run: source $SWIFT_ENV_FILE && ./build-debug.sh"
    else
        warn "Missing required deps. Re-run without --check to install."
    fi
    exit 0
fi

# --- Install: Homebrew --------------------------------------------------
if [[ $need_brew -eq 1 ]]; then
    say "Installing Homebrew (will prompt for sudo)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Bring brew onto PATH for the rest of this script.
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# --- Install: swiftly ---------------------------------------------------
# macOS install path is the signed .pkg from swift.org. The bash installer
# (swiftly-install.sh) requires GNU getopt from util-linux which is
# Linux-only — using it on macOS fails with:
#   "Error: getopt must be installed from the util-linux package"
# --- Install: Swift 6.2 toolchain (direct .pkg from swift.org) ---------
if [[ $need_swift -eq 1 ]]; then
    say "Downloading Swift $REQUIRED_SWIFT toolchain (~700 MB, 1–3 min)..."
    pkg_path="/tmp/${SWIFT_TOOLCHAIN_NAME}-osx.pkg"
    if [[ ! -f "$pkg_path" ]] || [[ $(stat -f%z "$pkg_path") -lt 100000000 ]]; then
        curl -fL -o "$pkg_path" "$SWIFT_PKG_URL" \
            || fail "Failed to download $SWIFT_PKG_URL"
    else
        say "Reusing cached $pkg_path"
    fi
    say "Installing toolchain to ~/Library/Developer/Toolchains/ (no sudo)..."
    installer -pkg "$pkg_path" -target CurrentUserHomeDirectory \
        || fail "Toolchain installer failed"
    [[ -x "$SWIFT_TOOLCHAIN_DIR/usr/bin/swift" ]] \
        || fail "Toolchain swift binary not found at $SWIFT_TOOLCHAIN_DIR/usr/bin/swift"
fi
say "Swift toolchain: $("$SWIFT_TOOLCHAIN_DIR/usr/bin/swift" --version | head -1)"

# --- Write env file the user sources before building -------------------
cat > "$SWIFT_ENV_FILE" <<EOF
# Source this before running ./build-debug.sh, ./swift-test.sh, etc.
# Generated by bootstrap.sh — re-runs of bootstrap.sh overwrite this file.
export PATH="$SWIFT_TOOLCHAIN_DIR/usr/bin:\$PATH"
export TOOLCHAINS="${SWIFT_TOOLCHAIN_NAME}"
EOF
say "Wrote $SWIFT_ENV_FILE — source it before building."

# --- If a broken swiftly install is lingering, warn ---------------------
if [[ -d "$HOME/.swiftly" ]] && [[ -x "$HOME/.swiftly/bin/swiftly" ]]; then
    warn "Detected leftover ~/.swiftly from a previous attempt."
    warn "  setup.sh routes through swiftly if it's on PATH — and swiftly"
    warn "  1.1.1 crashes on macOS 14 (malloc abort). Remove with:"
    warn "    rm -rf ~/.swiftly"
    warn "  and ensure no shell rc file sources ~/.swiftly/env.sh."
fi

# --- Install: optional extras (skip in --minimal) -----------------------
if [[ "$mode" != "minimal" ]]; then
    if [[ $need_xcbeautify -eq 1 ]]; then
        say "Installing xcbeautify (prettier xcodebuild output)..."
        brew install xcbeautify
    fi
    if [[ $need_bundler -eq 1 ]]; then
        say "Installing bundler (Ruby; release-only, for build-docs.sh)..."
        # System Ruby is fine for bundler.
        /usr/bin/sudo gem install bundler -n /usr/local/bin || warn "bundler install failed — only needed for ./build-release.sh"
    fi
fi

# --- Done ---------------------------------------------------------------
say "Dependencies installed."
cat <<EOF

Next steps:

  cd $(pwd)
  source $SWIFT_ENV_FILE   # adds Swift 6.2 toolchain to PATH for this shell
  ./build-debug.sh                       # ~1-2 min — compiles AeroSpace+CLI
  ./swift-test.sh                        # runs unit tests including
                                         # GridLayoutTest, GridResizeTest
  .debug/aerospace --help                # smoke-test the CLI

Caveats:

  • build-release.sh and install-from-sources.sh need Xcode 16.4+/17+/26
    (xcodebuild uses Xcode's bundled toolchain, not swiftly's). Your Xcode
    is $(xcodebuild -version | head -1). build-debug.sh has no such limit.
  • The phase-0 commit adds GridLayout/GridResize/WindowMemory but does
    NOT wire them into the running app. An installed binary will behave
    like vanilla AeroSpace until phase 1 lands. See docs/MUR_DESIGN.md.
EOF
