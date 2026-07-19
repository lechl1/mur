# justfile for mur — build, install, and run the daemon locally.
# Run `just` (or `just --list`) to see available recipes.

set shell := ["bash", "-uc"]

# Built debug artifacts (see build-debug.sh).
app    := justfile_directory() / ".debug/MurApp.app"
binary := app / "Contents/MacOS/MurApp"
cli    := justfile_directory() / ".debug/mur"

# Where the `mur` CLI symlink is installed.
prefix := "/usr/local"
log    := "/tmp/mur.log"

# Show available recipes.
default:
    @just --list

# We deliberately do NOT pin a toolchain here. Two things fight over the
# shared `.build` directory otherwise: SwiftPM refuses to import modules
# compiled by a different compiler, so mixing a pinned toolchain with the
# ambient Xcode one (used by `xcrun swift build`, IDEs, SourceKit) breaks
# the build with "module compiled with Swift X cannot be imported by the
# Swift Y compiler". Using the ambient Xcode toolchain everywhere keeps
# `.build` self-consistent. We still drop ~/.swiftly from PATH and clear
# TOOLCHAINS so `build-debug.sh` falls back to plain `swift` (swiftly
# 1.1.1's `run` aborts on this machine, and `.swift-version` may pin a
# toolchain that isn't installed).
#
# Build the debug bundle with the active Xcode Swift toolchain.
build *args:
    export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/.swiftly/' | paste -sd: -)"; unset TOOLCHAINS; bash build-debug.sh {{args}}

# Build, symlink the `mur` CLI onto PATH, and (re)start the daemon.
install: build
    install -d "{{prefix}}/bin"
    ln -sf "{{cli}}" "{{prefix}}/bin/mur"
    @just restart
    @echo "✅ Installed: {{prefix}}/bin/mur -> {{cli}}; daemon running (logs: {{log}})"

# Remove the CLI symlink and stop the daemon.
uninstall: stop
    -rm -f "{{prefix}}/bin/mur"
    @echo "🗑  Removed {{prefix}}/bin/mur"

# Relaunch the daemon detached so global hotkeys register (see CLAUDE.md).
restart: stop
    (nohup "{{binary}}" >"{{log}}" 2>&1 &) ; disown 2>/dev/null || true
    @echo "▶  Daemon started — logs at {{log}}"

# Stop the running daemon.
stop:
    -pkill -f "MurApp.app/Contents/MacOS/MurApp"
    @sleep 1

# Follow the daemon log.
logs:
    tail -f "{{log}}"
