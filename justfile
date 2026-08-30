# justfile for mur — build, install, and run the daemon locally.
# Run `just` (or `just --list`) to see available recipes.

set shell := ["bash", "-uc"]

# Built debug artifacts (see build-debug.sh).
app    := justfile_directory() / ".debug/MurApp.app"
binary := app / "Contents/MacOS/MurApp"
cli    := justfile_directory() / ".debug/mur"

# Where `just install` puts things. The app goes to /Applications so it
# is launchable from Finder / Spotlight; the CLI is symlinked onto PATH
# from *inside* the installed bundle, so it keeps working if the source
# tree moves away.
install_dir      := "/Applications"
installed_app    := install_dir / "Mur.app"
installed_binary := installed_app / "Contents/MacOS/MurApp"
installed_cli    := installed_app / "Contents/MacOS/mur"

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

# Build, install the app into /Applications, put the `mur` CLI on PATH,
# and (re)start the daemon. Stop first: you can't overwrite the
# executable of a running bundle.
install: build stop
    bash install-app.sh
    install -d "{{prefix}}/bin"
    ln -sf "{{installed_cli}}" "{{prefix}}/bin/mur"
    @just start
    @echo "✅ Installed {{installed_app}} + {{prefix}}/bin/mur (logs: {{log}})"
    @echo "   Launchable from Finder/Spotlight. First launch from there needs its own"
    @echo "   Accessibility grant: System Settings → Privacy & Security → Accessibility → Mur."

# Remove the installed app and the CLI symlink, and stop the daemon.
uninstall: stop
    -rm -f "{{prefix}}/bin/mur"
    bash install-app.sh --uninstall
    @echo "🗑  Removed {{prefix}}/bin/mur"

# Launch the daemon detached so global hotkeys register (see CLAUDE.md):
# the installed app if there is one, otherwise the debug bundle.
start:
    #!/usr/bin/env bash
    set -uo pipefail
    if test -x "{{installed_binary}}"; then bin="{{installed_binary}}"; else bin="{{binary}}"; fi
    (nohup "$bin" >"{{log}}" 2>&1 &) ; disown 2>/dev/null || true
    echo "▶  Started $bin — logs at {{log}}"

# Restart the daemon.
restart: stop start

# Stop the running daemon (installed or debug — the pattern matches both).
stop:
    -pkill -f "Mur(App)?\.app/Contents/MacOS/MurApp"
    @sleep 1

# Follow the daemon log.
logs:
    tail -f "{{log}}"
