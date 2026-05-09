#!/usr/bin/env bash
# bootstrap.sh — install build dependencies for mur.
#
# Idempotent: safe to re-run. Does NOT touch your existing Xcode install.
#
# What it installs:
#   • Homebrew                (if missing)
#   • swiftly                 (Swift toolchain manager — alongside Xcode)
#   • Swift 6.2.0             (mur's Package.swift requires it; Xcode 15 ships 5.10)
#   • xcbeautify              (prettier xcodebuild output — optional)
#   • bundler                 (Ruby gem; only needed for `build-release.sh` docs)
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

REQUIRED_SWIFT="6.2.0"
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

# --- swiftly -------------------------------------------------------------
need_swiftly=0
if ! command -v swiftly >/dev/null 2>&1 && ! [[ -x "$HOME/.local/share/swiftly/bin/swiftly" ]]; then
    need_swiftly=1
fi

# --- Swift 6.2 (via swiftly if present) ---------------------------------
need_swift=1
if command -v swiftly >/dev/null 2>&1; then
    if swiftly list 2>/dev/null | grep -q "$REQUIRED_SWIFT"; then need_swift=0; fi
fi

# --- xcbeautify, bundler (optional) -------------------------------------
need_xcbeautify=0
if ! command -v xcbeautify >/dev/null 2>&1; then need_xcbeautify=1; fi
need_bundler=0
if ! command -v bundle >/dev/null 2>&1; then need_bundler=1; fi

# --- Report --------------------------------------------------------------
echo "Dependency check:"
printf "  Homebrew    : %s\n" "$([[ $need_brew      -eq 0 ]] && echo "OK" || echo "MISSING")"
printf "  swiftly     : %s\n" "$([[ $need_swiftly   -eq 0 ]] && echo "OK" || echo "MISSING")"
printf "  Swift %s : %s\n" "$REQUIRED_SWIFT" "$([[ $need_swift -eq 0 ]] && echo "OK" || echo "MISSING")"
printf "  xcbeautify  : %s\n" "$([[ $need_xcbeautify -eq 0 ]] && echo "OK" || echo "missing (optional)")"
printf "  bundler     : %s\n" "$([[ $need_bundler   -eq 0 ]] && echo "OK" || echo "missing (optional, release-only)")"
echo

if [[ "$mode" == "check" ]]; then
    if [[ $need_brew -eq 0 && $need_swiftly -eq 0 && $need_swift -eq 0 ]]; then
        say "All required deps present. Run ./build-debug.sh"
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
if [[ $need_swiftly -eq 1 ]]; then
    say "Installing swiftly (Swift toolchain manager)..."
    # Non-interactive install. swiftly's installer respects SWIFTLY_HOME_DIR
    # and reads -y for unattended.
    curl -L -o /tmp/swiftly-install.sh https://swiftlang.github.io/swiftly/swiftly-install.sh
    chmod +x /tmp/swiftly-install.sh
    /tmp/swiftly-install.sh -y --no-modify-profile
fi
# Source swiftly env for this shell.
if [[ -f "$HOME/.local/share/swiftly/env.sh" ]]; then
    # shellcheck disable=SC1091
    . "$HOME/.local/share/swiftly/env.sh"
fi
command -v swiftly >/dev/null 2>&1 || fail "swiftly not on PATH after install. Open a new shell and re-run."

# --- Install: Swift 6.2 -------------------------------------------------
if [[ $need_swift -eq 1 ]]; then
    say "Installing Swift $REQUIRED_SWIFT (download ~600 MB, takes 3–5 min)..."
    swiftly install --use "$REQUIRED_SWIFT"
fi
swiftly use "$REQUIRED_SWIFT" >/dev/null
say "Swift toolchain: $(swiftly run swift --version | head -1)"

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
  source ~/.local/share/swiftly/env.sh   # add to ~/.zshrc to persist
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
