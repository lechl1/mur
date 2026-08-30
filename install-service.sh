#!/bin/bash
# mur — install mur as a per-user launchd service with crash protection.
#
#   bash install-service.sh              # install + start (debug bundle)
#   MUR_APP=/Applications/Mur.app bash install-service.sh
#   bash install-service.sh --uninstall  # stop + remove
#   bash install-service.sh --status     # is it loaded / running?
#
# Crash protection comes from launchd: `KeepAlive.SuccessfulExit = false`
# restarts MurApp whenever it dies with a non-zero status (crash, kill -9,
# OOM) but leaves it stopped when it exits cleanly — so `mur enable off`
# and an explicit quit still work as a quit. `ThrottleInterval` keeps a
# crash loop from spinning: launchd waits between relaunches.
#
# NB: the service launches the app binary directly, the same way the
# manual `nohup … & disown` dance does. Launching through `open` breaks
# global hotkey registration (see CLAUDE.md); launchd does not.
set -euo pipefail

LABEL="com.mur.MurApp"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUI="gui/$(id -u)"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

resolve_app() {
    if [[ -n "${MUR_APP:-}" ]]; then
        # Accept either the .app bundle or the executable itself.
        if [[ -d "$MUR_APP" ]]; then echo "$MUR_APP/Contents/MacOS/MurApp"; else echo "$MUR_APP"; fi
        return
    fi
    # Prefer the installed app (`just install`) over the source-tree debug
    # bundle: the service should survive the repo moving or being cleaned.
    for candidate in \
        "/Applications/Mur.app/Contents/MacOS/MurApp" \
        "$REPO/.debug/MurApp.app/Contents/MacOS/MurApp" \
        "$REPO/.release/MurApp.app/Contents/MacOS/MurApp"
    do
        if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
    done
    echo ""
}

status() {
    if launchctl print "$GUI/$LABEL" >/dev/null 2>&1; then
        echo "service: loaded ($LABEL)"
        launchctl print "$GUI/$LABEL" | grep -E "^\s+(state|pid|last exit code) " || true
    else
        echo "service: not loaded ($LABEL)"
    fi
    pgrep -f "MurApp.app/Contents/MacOS/MurApp" >/dev/null 2>&1 \
        && echo "process: running (pid $(pgrep -f 'MurApp.app/Contents/MacOS/MurApp' | tr '\n' ' '))" \
        || echo "process: not running"
}

uninstall() {
    launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Uninstalled $LABEL (plist removed). Any running MurApp was left alone."
}

case "${1:-}" in
    --uninstall) uninstall; exit 0 ;;
    --status)    status;    exit 0 ;;
    --help|-h)   usage;     exit 0 ;;
    "")          ;;
    *)           echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

APP="$(resolve_app)"
if [[ -z "$APP" ]]; then
    echo "Can't find a MurApp binary. Build one first (bash build-debug.sh)" >&2
    echo "or point MUR_APP at the bundle: MUR_APP=/Applications/Mur.app $0" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                  <string>$LABEL</string>
    <key>ProgramArguments</key>       <array><string>$APP</string></array>
    <key>RunAtLoad</key>              <true/>
    <!-- Crash protection: relaunch on abnormal exit, stay down on a clean quit. -->
    <key>KeepAlive</key>              <dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key>       <integer>10</integer>
    <key>ProcessType</key>            <string>Interactive</string>
    <key>LimitLoadToSessionType</key> <string>Aqua</string>
    <key>StandardOutPath</key>        <string>$LOG_DIR/mur.log</string>
    <key>StandardErrorPath</key>      <string>$LOG_DIR/mur.log</string>
</dict>
</plist>
EOF

# Replace any previous instance, then hand the running app over to launchd
# so the service — not a stray shell-launched copy — owns the process.
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
pkill -f "MurApp.app/Contents/MacOS/MurApp" 2>/dev/null || true
sleep 1
launchctl bootstrap "$GUI" "$PLIST"
launchctl enable "$GUI/$LABEL"
sleep 2

echo "Installed $LABEL"
echo "  binary: $APP"
echo "  plist:  $PLIST"
echo "  log:    $LOG_DIR/mur.log"
status
