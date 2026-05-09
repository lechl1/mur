# mur

## Restarting the daemon after a debug build

After `bash build-debug.sh`, restart the running daemon by killing it and
relaunching the binary directly with `nohup` + `disown` — **not** with
`open <bundle>`. Launching via `open` (or any path that keeps the app
attached to the invoking shell session) breaks global hotkey registration:
the keybindings appear active but never fire.

```bash
pkill -f "MurApp.app/Contents/MacOS/MurApp" 2>/dev/null
sleep 1
(nohup /Users/leochl/workspace/mur/.debug/MurApp.app/Contents/MacOS/MurApp \
    >/tmp/mur.log 2>&1 &)
disown 2>/dev/null
```

The subshell + `disown` detach the process from the shell so hotkey
registration survives the launching session exiting.

## Building

The project requires Swift 6.2. The system default `swift` is 5.10, so
export the toolchain before running the build script:

```bash
export TOOLCHAINS=org.swift.6200202509111a
bash build-debug.sh
```
