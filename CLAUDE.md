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
