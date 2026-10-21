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
  (0.4)** — deliberately below `1.0` so columns render at their natural width
  and **center** instead of auto-expanding to fill (that was the whole point of
  the naru port). In `resolveRect`, if the used columns' total desired width is
  **≤ 1** the strip renders at those widths and is **centered**; if it
  **exceeds 1** the columns shrink by a shared factor to fill
  (`denom = max(1, totalLaneWeight)` unifies both). So one column → half width
  centered; two → fill; three-plus → shrink to fit. A lone terminal (`1/3` via
  `setLaneAbsoluteWidth`) renders centered. The slot axis (rows within a
  column) still fills the column. `cellAt` mirrors the same math.
- **A window's minimum size wins.** Some apps refuse to go narrower than a
  minimum (Spotify: ~800px). The post-layout fill check
  (`scheduleFillCheck`) notices a window still bigger than its cell, keeps
  re-asking, and records `StackingLayout.minimumSizes` only when the answer
  is unambiguous: a visible workspace, the same oversized size for ~1.5s,
  and under 90% of the screen. A wrong minimum is never forgotten and pins
  the column wide (Spotify once "learned" 2056px and covered the screen),
  so a slow app or a hidden workspace must not teach one. Then it lays out
  again. `StackingLayout.laneExtents` (shared by `resolveRect` and `cellAt`)
  widens that column to the minimum, taking the room first from empty screen
  (a centred strip grows) and then from the other columns in proportion to
  their widths, never below their own minimums. Stored lane weights are not
  touched. Only the lane-axis component counts (width in landscape, height in
  portrait). The layout overview HUD (`StackingHud`) draws columns from
  `laneExtents` too, never from the raw weights, so it matches the screen.
- **Resize-towards-center.** Mouse-resizing a column's lane-axis edge sets its
  **absolute** width from the dragged extent (`StackingResize.snap`); neighbours
  keep their widths and fit-or-center re-centers the strip, so a column grows /
  shrinks symmetrically about the centre instead of shoving one neighbour.
- **A closing column's space goes back to the survivors, which then FILL
  the screen.** When the last window in a column goes away, the remaining
  columns scale up **proportionally** until they cover the whole lane axis:
  no gap where the column was, and no slack at the edges either. They keep
  their sizes relative to each other, so a column that was twice its
  neighbour still is. `StackingLayout.redistributeWidthOfClosingLanes`
  normalises the surviving weights to sum to exactly 1 — `resolveRect`
  renders lane `i` at `w_i / max(1, total)`, so a total of 1 spans edge to
  edge. That also keeps the stored total from ratcheting up over a long
  session, since every close lands back on 1.
  This deliberately overrides fit-or-center **on close**: opening columns
  still centres a narrow strip (the naru feel, and it stays), but leaving
  the screen part-empty after a close reads as mur failing to react. Two
  earlier rules were both wrong here — "survivors keep their on-screen
  width", then "survivors preserve the total" (which left a 0.4-wide strip
  0.4 wide, the visible bug). Losing one ROW of a multi-row column still
  changes nothing: only a column closing redistributes.
- **A column opening beside a FULL screen takes an equal share.** If the
  existing columns already fill the lane axis (total ≥ 1), a newcomer gets
  their average width (`StackingLayout.widthForNewColumn`), so it renders
  at `1/(n+1)` and the others shrink proportionally — one full-width
  terminal plus a new one is 50/50, not 75/25. A narrow strip still opens
  the newcomer at its natural width and centres. Columns already on screen
  keep their widths when a window joins: only the startup restore resets
  widths to defaults.

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
- **One window per cell; a window never starts floating.** Two windows may
  never share a `(lane, slot)` — they'd resolve to identical rects and render
  as one window swallowing the other. `StackingLayout.place` enforces this by
  pushing the occupant (and everything below it in the lane) down a slot, so a
  placement INSERTS rather than lands on top. A new window is mounted into the
  grid **synchronously at registration** (`tryRegisterInStackingLayout`) —
  never parked as floating to be mounted later. An earlier "float first,
  mount a beat later" scheme left windows floating whenever the later mount
  never came (a window back from minimize/fullscreen re-registers with no
  restore queued). The double move it guarded against (sync heuristic cell,
  then the async restore's remembered cell) is avoided instead by
  `openedLaterIds`: outside restore mode, a window opened while mur is running
  keeps the cell it was mounted in and is only *remembered* by title. Only
  apps that are floating by design (`floatByDefaultBundleIds`, known
  non-resizable apps) start floating. **In the grid ⇒ tiled in the tree**
  (`tileInTreeIfInGrid`, enforced on every layout): the inherited dialog
  heuristic floats a window that registers while it looks like a dialog
  (Spotify while hidden or launching), the grid mounted it anyway, and it
  rendered tiled while drag / `resize` / `list-windows` called it floating. **Floating is never persisted or
  restored**: `WindowMemory.recall` treats an old floating entry as a miss.
  Replaying floating state is how windows that were only briefly floating
  (the float-first mount, an auto-float) stayed floating across every
  restart. The
  restore also ranks remembered lanes against the **current** layout's free
  lanes, never back to column 0, so a newcomer can't be ranked onto an
  existing column.

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

## The refresh loop must always finish

Everything mur does in the background — noticing a window closed, pulling
a mouse-dragged window back into its cell, pruning a dead cell so the
survivors grow — happens inside a *refresh session*. Two rules keep that
loop alive, and both were learned from bugs that looked like layout bugs:

- **Bound every AX wait.** An app can stop answering the Accessibility API
  while still running and still listed in `runningApplications`. An
  unbounded `await` on such an app never returns, and
  `refreshAllAndGetAliveWindowIds` waits for *every* app, so one wedged
  app stopped every refresh in the process. `refreshOneApp` wraps
  registration AND the query in `withAxDeadline` (2s), then skips that app
  for `unresponsiveAppRetryAfter` (10s) so the cost is paid once, not on
  every refresh. A timed-out app reports **the windows mur already knows**,
  never `[]` — the caller garbage-collects anything missing from the
  result, so an empty list would read as "this app closed all its windows".
- **Coalesce, don't preempt.** `scheduleCancellableCompleteRefreshSession`
  used to cancel the refresh in flight on every incoming event. mur's own
  layout feeds that queue — `setAxFrame` → `AXMoved`/`AXResized` →
  another refresh — so refreshes cancelled each other indefinitely.
  Measured live: **every** background refresh ended in
  `CancellationError`, some after 1ms. Now a refresh runs to completion
  and whatever arrives meanwhile is kept as ONE follow-up. That is sound
  because refreshes are idempotent (state is recomputed, not accumulated)
  and it terminates because a refresh that changes nothing emits no
  notifications. `runLightSession` still cancels — an explicit command
  outranks a background refresh.

Symptom to recognise: mur ignores a window closing or a dragged window,
and then **any CLI command fixes it instantly** — because a command runs a
non-cancellable light session. That is never a layout bug; the layout code
is fine and never ran. `mur stacking-info` is itself such a poke, so it
destroys the evidence: measure window frames with System Events (or watch
the screen) instead of asking mur.

Window destruction is also subscribed on the **application** element, not
only per window (`MacApp`'s app-level handlers). `kAXUIElementDestroyed`
delivered to a dying window's own element is unreliable — for some apps it
never arrives, and the close then went unnoticed until an unrelated event
woke mur up.

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
  ask and the record is consumed once. The store keeps **one session per
  terminal window**, grouped by cwd — several terminals in one repo is
  normal, and a single slot per cwd restored them all into the same cell,
  stacking them as rows of one column on every restart. Within a cwd the
  **title** tells them apart (`pickTerminalSession`: same normalised title
  first, then the next unclaimed one in screen order), and each saved
  session is claimed at most once per run. Ghostty exposes no settable
  per-window metadata over AX (`AXIdentifier` is the same on every window);
  its AppleScript window ids look like pointers and aren't a stable handle;
- a title miss falls back to the app's remembered cells
  (`recallTiledByApp`), handed out **workspace-major** — ordering by cell
  alone interleaves workspaces, since every workspace has a lane 0;
- an unrecognised window with no cell left to hand out goes to
  `dominantWorkspace(appId:)` — where that app lives — instead of staying
  put. Restore mode only: a window opened later really is new, and belongs
  on the workspace the user is looking at.

Outside restore mode a window is **never** steered to a remembered
workspace — a window the user opens joins the workspace it opened on
(moving it made it vanish the moment it appeared). In restore mode, a
window that opened after the startup batch is steered only on a match that
names it (title / terminal session), never on the app-pool guess.

**Restore is a window of time, not one batch** (naru's `RESTORE_SETTLE`).
The coordinated restore is debounced 90ms, which catches every window that
already existed — but not the ones mur is *waiting* for: a terminal mur
relaunches takes seconds to map, a browser reopening tabs longer. So
restore mode stays on for `restoreSettle` (60s) and ends early once every
remembered window has been claimed (`unclaimedRestoreEntries`).

## Restoring a claude session

A restored terminal is relaunched with `claude --resume <session-id>`, not
a bare `--resume` — which opens the interactive session PICKER and leaves
every restored terminal sitting at a chooser. The id is resolved
(`claudeSessionId(forCwd:)`, ported from naru's `session/claude.rs`) from
`~/.claude/projects/<encoded-cwd>/<id>.jsonl`, newest transcript first,
where the encoding replaces every non-alphanumeric character with `-`.
That encoding is **lossy** (`/a/b` and `/a.b` both give `-a-b`), so a
candidate is confirmed against the `cwd` recorded inside the transcript
before its id is trusted. Transcripts run to megabytes; only a bounded
head is read.

## Linting: bugs only

`.swiftlint.yml` is a **bug detector, not a style guide**. Every rule in it
names something that can misbehave at runtime — a swallowed error, a leaked
observer, a comparison that's always true, a test that silently never runs —
and `strict: true` makes each one an error. Formatting is SwiftFormat's job
(`./format.sh` rewrites the code instead of complaining about it), so no
spacing / ordering / naming / line-width rule belongs in the lint config.
The bar for adding a rule: it must name a defect. Rules deliberately left
off (`force_cast`, `force_unwrapping`, `implicitly_unwrapped_optional`,
`async_without_await`, `optional_data_string_conversion`) are listed in the
file with the reason — don't re-add one without answering it.

`bash lint.sh` runs the whole gate: SwiftFormat → SwiftLint → **periphery**
(unused-code detection, also `--strict`). Periphery counts as part of the
bug set: dead code is code no test covers and no reader can trust. Two
fields carry `// periphery:ignore` with a reason — a Hashable key component
and an on-disk schema marker, both genuinely used, just not by a reader in
this codebase.

`fireAndForget { … }` (in `Common/util/commonUtil.swift`) exists because of
one of these rules: `Task { try await … }` parks whatever the body throws
in a result nobody reads. mur's convention is that `throws` carries only
`CancellationError`, so the helper ignores exactly that and logs anything
else. Pass `@MainActor in` where the `Task` it replaced inherited main-actor
isolation — the helper's body is `@Sendable`, so it starts nonisolated
otherwise.

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

**A missing grant looks exactly like a broken layout engine.** With no
Accessibility, `mur list-windows --all` prints nothing, no window ever
tiles, and every hotkey is inert — nothing in that picture points at
permissions. Check the window list FIRST when mur "stops working": empty
means TCC, not layout. The confusing part is that launching the binary
from a terminal inherits *that terminal's* grant, so the same build works
from the shell and is dead when launched from Finder or launchd.

An ad-hoc signature has no stable designated requirement, so TCC keys the
grant to the binary's cdhash and **every `just install` revokes it**. Set
`MUR_CODESIGN_IDENTITY`, or create a self-signed code-signing certificate
named `mur-dev` (Keychain Access → Certificate Assistant), and
`install-app.sh` signs with it instead — then the grant survives rebuilds.

When mur is untrusted the menu-bar item reads
`⚠️ mur: grant Accessibility` instead of the workspace list
(`updateTrayText`), because the old signal was a `print` that nobody sees
when the app was launched from Finder.

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

## No restart wrapper — mur handles its own failures

mur is **not** run under a crash-restarting supervisor (launchd
`KeepAlive`) and has no self-aborting main-thread watchdog. Both existed
briefly and the watchdog itself was the crash: its check closure was
written inside a `@MainActor` function, so Swift 6 treated it as
main-actor isolated and trapped in `dispatch_assert_queue` when it ran on
a global queue — 30s after every launch, which launchd turned into a
crash loop (and every relaunch of an ad-hoc-signed build re-raised the
Accessibility prompt). A restart loop also hides bugs instead of fixing
them. Failures are caught and handled inside mur: bound the wait
(`withAxDeadline`), log and carry on (`fireAndForget`), degrade instead of
trapping (e.g. `laneWeight` tolerating a short weights array).

## Building

Build with **`just build`** (or `just install`, which calls it). It strips
swiftly from `PATH` and unsets `TOOLCHAINS`, so the build runs on Xcode's
default Swift — currently 6.3.3, comfortably past the 6.2 the package
needs. `build-debug.sh` on its own routes `swift` through
`swiftly run swift`, which obeys the checked-in `.swift-version`
(`6.3.0`); swiftly has no toolchains installed here, so that path fails
with "doesn't match any of the installed toolchains".

Do **not** build with `TOOLCHAINS=org.swift.6200202509111a` (older advice
that used to live here, from when the default `swift` was 5.10). It works
in isolation, but the 6.2 modules it leaves in `.build` are then rejected
by the 6.3.3 compiler `just build` uses — "module compiled with Swift 6.2
cannot be imported" — and the only way out is `rm -rf .build`.

`bash swift-test.sh` and `bash lint.sh` need the same treatment as
`just build`:

```bash
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/.swiftly/' | paste -sd: -)"
```
