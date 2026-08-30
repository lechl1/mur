# mur

## Layout model — columnar, not binary-split

mur's window layout is **columnar**, not a recursive binary/nested split
tree like i3/sway. This is a core design invariant: keep it that way.

- The workspace is partitioned into a rigid set of **lanes**, and each lane
  holds a dynamic stack of **slots**. A window maps directly to a
  `(lane, slot)` cell — there is no arbitrarily-nested container tree and no
  binary splitting. Do **not** reintroduce a binary/recursive split model.
- **Each column may hold multiple rows.** In the common orientation a lane is
  a column and its slots are the rows stacked within it.
- **Portrait and landscape work equally, but inverted.** Orientation is
  chosen from the monitor's aspect (`LayoutOrientation.forMonitor`):
  - **landscape** → lanes run left→right (columns), slots run top→bottom (rows);
  - **portrait** → lanes run top→bottom (rows), slots run left→right (columns).
  The lane/slot code is orientation-neutral; only the final geometry
  (`StackingLayout.resolveRect`) branches on orientation, so columns become
  rows and vice-versa when the monitor rotates.
- **Fit-or-center along the lane axis (naru-style, carousel disabled).**
  Lane weights are **absolute** desired widths, as a fraction of the lane-axis
  extent. The default column width is **`StackingLayout.defaultColumnWidth`
  (0.5)** — deliberately below `1.0` so columns render at their natural width
  and **center** instead of auto-expanding to fill (that was the whole point of
  the naru port). In `resolveRect`, if the used columns' total desired width is
  **≤ 1** the strip renders at those widths and is **centered**; if it
  **exceeds 1** the columns shrink by a shared factor to fill
  (`denom = max(1, totalLaneWeight)` unifies both). So one column → half width
  centered; two → fill; three-plus → shrink to fit. A lone terminal (`1/3` via
  `setLaneAbsoluteWidth`) renders centered. The slot axis (rows within a
  column) still fills the column. `cellAt` mirrors the same math.
- **Resize-towards-center.** Mouse-resizing a column's lane-axis edge sets its
  **absolute** width from the dragged extent (`StackingResize.snap`); neighbours
  keep their widths and fit-or-center re-centers the strip, so a column grows /
  shrinks symmetrically about the centre instead of shoving one neighbour.
- **No empty columns.** A lane only exists while a window can actually
  render in it. `layoutWorkspaceWithStacking` prunes cells whose window is
  gone, has moved workspace, or sits in a macOS-native shim container
  (minimized / fullscreen / hidden app) before resolving geometry, and
  `remove()`'s `compactGaps()` closes ranks. On top of that, a *tiled*
  window minimized behind mur's back (⌘M, or an app minimizing itself) is
  auto-restored by `normalizeLayoutReason` so its column never goes empty
  — mur gives up after `autoUnminimizeGiveUpAfter` (2s) if the app insists.
  An explicit `macos-native-minimize` opts out (it records the window in
  `intentionallyMinimizedWindowIds`) and frees the cell instead.
- **One window per cell; float first, mount a beat later.** Two windows may
  never share a `(lane, slot)` — they'd resolve to identical rects and render
  as one window swallowing the other. `StackingLayout.place` enforces this by
  pushing the occupant (and everything below it in the lane) down a slot, so a
  placement INSERTS rather than lands on top. On top of that, a window that
  opens while mur is already running is bound as a **floating** window at
  registration and joins the grid ~90ms later from `runCoordinatedRestore`
  (`pendingGridMountIds` in `StackingPlacement.swift`): the sync registration
  path can't read a window title, so mounting there and then re-placing from
  window memory moved the window twice — the visible "new window jumps across
  the screen". Startup is exempt (one batch, `isStartup`). The restore also
  ranks remembered lanes against the **current** layout's free lanes, never
  back to column 0, so a newcomer can't be ranked onto an existing column.

- **Spring animations.** Windows glide to their target rects via
  `WindowAnimator` (critically-damped spring, stiffness 800) rather than an
  instant `setAxFrame`. The animator drives per-frame `setAxFrame`s on a 60 fps
  timer and lists driven windows in `animatingIds`; the AX move/resize
  observers ignore notifications for those ids so the animation can't cause a
  refresh storm. Master switch: `WindowAnimator.enabled`.

Implementation lives in `Sources/AppBundle/layout/StackingLayout.swift`
(`LayoutOrientation`, `LayoutShape`, `TileSpan`, `StackingLayout`), driven by
`layoutWorkspaceWithStacking()` in `Sources/AppBundle/layout/layoutRecursive.swift`.
It is gated by the `experimental-stacking-layout` config flag, which now
**defaults to true** (`Config.swift`). AeroSpace's legacy tree
(`Sources/AppBundle/tree/TilingContainer.swift`, `layoutRecursive`/
`layoutTiles`/`layoutAccordion`) remains only as the dormant fallback when the
flag is off; it is not mur's model.

## Restore is workspace-aware

macOS has no workspaces to read back, so at startup **every** window is
registered into whichever workspace happens to be active. The workspace a
window belongs to therefore only exists in mur's own memory
(`WindowMemory` entries and `TerminalSession`s both store a workspace
name), and `runCoordinatedRestore` must move each window to its
remembered workspace. Any path that loses that name drops the window on
the active workspace — the "windows jump back to the first workspace"
bug. The three fallbacks all carry a workspace now:

- a terminal is identified by **cwd**, resolved through
  `resolveTerminalCwd` (never `window.cwd` alone): a session mur itself
  relaunched runs `claude` directly, so no shell integration runs and
  Ghostty never publishes `AXDocument` for it. Adoption of a spawn record
  is sticky (written into `lastKnownTerminalCwd`) because several callers
  ask and the record is consumed once;
- a title miss falls back to the app's remembered cells
  (`recallTiledByApp`), handed out **workspace-major** — ordering by cell
  alone interleaves workspaces, since every workspace has a lane 0;
- an unrecognised window with no cell left to hand out goes to
  `dominantWorkspace(appId:)` — where that app lives — instead of staying
  put. Startup batch only (`isStartupRestore`, the first coordinated
  restore): a window opened later really is new, and belongs on the
  workspace the user is looking at.

## Installing (`just install`)

`just install` builds the debug bundle, installs it as
**`/Applications/Mur.app`** (`install-app.sh`), symlinks the CLI shipped
*inside* that bundle to `/usr/local/bin/mur`, and restarts the daemon
from the installed copy. So the app is launchable from Finder/Spotlight
and the CLI keeps working if the source tree moves.

`install-app.sh` assembles the bundle by hand from the SwiftPM products
(executable + Info.plist + ad-hoc signature + an `AppIcon.icns` built
with `sips`/`iconutil` — `actool` needs an Xcode IDE plugin host that is
often broken); `build-release.sh` is not used because it wants a codesign
certificate, a universal build and a clean worktree.

Accessibility is per-bundle-path, so the first launch of
`/Applications/Mur.app` **from Finder** raises a fresh "control this
computer" prompt even if `.debug/MurApp.app` was already approved — until
it's granted, hotkeys register but the commands they run do nothing.
`just install` prints that reminder. `just uninstall` removes both.

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

## Running mur as a service (crash protection)

`bash install-service.sh` installs a per-user launchd agent
(`~/Library/LaunchAgents/com.mur.MurApp.plist`) that runs the MurApp binary
directly — never via `open`, which would break hotkey registration — with
`KeepAlive.SuccessfulExit = false`, so launchd relaunches it after a crash
but leaves it down after a clean quit. `--status` / `--uninstall` do what
they say; logs go to `~/Library/Logs/mur.log`.

Caveat: a launchd-launched MurApp is its own TCC client. Launching it from a
terminal inherits that terminal's Accessibility grant, launchd does not — so
the first service start raises the "control this computer" prompt and mur
sees zero windows until it's approved. An ad-hoc `codesign -s -` build gets a
new identity on every rebuild, which can require re-approving it.

## Building

The project requires Swift 6.2. The system default `swift` is 5.10, so
export the toolchain before running the build script:

```bash
export TOOLCHAINS=org.swift.6200202509111a
bash build-debug.sh
```
