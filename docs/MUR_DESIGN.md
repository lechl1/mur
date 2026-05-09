# Mur Design — Predefined Grid Layouts

Mur is a fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace) that
**removes the tree-based layout engine** and replaces it with **predefined,
fixed-shape grid layouts**.

This document is the source of truth for the layout semantics. Anything in
the inherited AeroSpace codebase that contradicts this doc is wrong and is
slated for removal.

## Goals

1. **No layout trees.** No `TilingContainer`, no recursive split nodes, no
   orientation flips. A workspace has *one* active grid layout, period.
2. **Orientation-aware: rigid lanes, flexible slots-per-lane.**
   A workspace has a fixed number of **lanes** (3 by default). Lanes
   are rigid: equal extent, fixed positions, no swapping. Each lane
   partitions independently into **slots** whose extent is weighted.
   The orientation of the active monitor decides the axis mapping:
    - **Landscape** (`width > height`): lane = column (rigid x-position
      and width), slot = row within a column (flexible y-extent). Left
      column may have 4 rows, middle 2, right 3.
    - **Portrait** (`height >= width`): lane = row (rigid y-position
      and height), slot = column within a row (flexible x-extent). Top
      row may have 4 cols, middle 2, bottom 3.

   Same model, axes swapped. All semantics below apply to both.
3. **Tiles, not splits.** A window's geometry is a **tile span**:
   `(lane, slot0..slot1)` — a contiguous run of slots in a single lane.
   No cross-lane spans. Most placements are single-slot (`slot0 == slot1`).
4. **Per-lane slot weights.** Within a lane, slot extents are weighted
   (default 1.0 each). Mouse drag along the **slot axis** (vertical in
   landscape, horizontal in portrait) redistributes weight between
   adjacent slots — same continuous feel as AeroSpace's resize. Drag
   along the **lane axis** is rigid (no-op or snap-back).
5. **Stacking is first-class.** Multiple windows can occupy overlapping
   spans within the same column. Z-order is explicit and updates on focus.
6. **Empty columns collapse.** If a column has zero windows, it contributes
   0 width — the remaining columns expand to fill. Within a column, empty
   row-slots compact (row indices reindex when a window leaves).
7. **Floating still works.** A window can opt out of the grid and float,
   exactly as in AeroSpace.
8. **Sticky placement memory.** When a known window (matched by app id +
   window title) opens, it reuses its last `(col, row0, row1)`. Otherwise
   the placement heuristic chooses one.

## Non-goals

- BSP / accordion / dwindle / column / row layouts from i3 or AeroSpace.
- Resize-by-pixel of individual tiles. Tiles are **structural**, not pixel-resizable.
  (You change the grid by *changing the layout*, not by dragging gutters.)
- Per-tile gaps that differ from per-grid gaps.

## Core types

### `LayoutOrientation`

```
enum LayoutOrientation { case landscape; case portrait }
```

Decides axis assignment. Detected from monitor rect at attach time.
`width >= height` → landscape; otherwise portrait.

### `LayoutShape`

```
struct LayoutShape { let orientation: LayoutOrientation; let lanes: Int }
```

`lanes` is the number of rigid lanes (default 3). In landscape, lanes
are columns. In portrait, lanes are rows.

### `TileSpan`

```
struct TileSpan {
    let lane: Int           // 0..<shape.lanes
    let slot0: Int          // inclusive
    let slot1: Int          // inclusive, >= slot0
}
```

A window occupies a single lane and a contiguous run of slots inside that
lane. Slot count per lane is dynamic — derived from `max(slot1) + 1` over
the lane's placements. Most placements have `slot0 == slot1`. Spans
**may overlap** other windows' spans within the same lane (stacking).

### `GridLayout` (per workspace)

```
final class GridLayout {
    let shape: GridShape
    private(set) var placements: [WindowId: TileSpan]
    private(set) var zOrder: [WindowId]   // back → front
}
```

`placements` defines membership in the grid. Windows not in `placements` are
either floating (registered on the workspace's float list) or unmanaged
(macOS native fullscreen, popups, etc.) — same handling as AeroSpace.

`zOrder` is a topological list of grid windows, back to front. Newer windows
go on top. The OS focus order can drift from `zOrder`; on focus we promote
the focused window to the end of `zOrder`.

### `WindowMemory` (per-app, per-title)

```
struct WindowMemoryKey: Hashable {
    let appId: String        // bundle id
    let windowTitle: String  // exact match
}

final class WindowMemory {
    var entries: [WindowMemoryKey: TileSpan]
}
```

Persisted to `~/.config/mur/window-memory.json` (or platform-equivalent).
Updated whenever a window's span changes (open, manual move, layout switch).

## Geometry: collapsing empty tracks

The "empty rows/cols collapse" rule is computed at layout time, not when
spans are mutated:

1. Let `usedCols = { c | ∃ w. w.span.col0 ≤ c ≤ w.span.col1 }` and same for rows.
2. If `usedCols` or `usedRows` is empty (workspace has zero tiled windows),
   skip — there is nothing to lay out. Floats still render.
3. Otherwise, the workspace's visible rect is divided into
   `|usedCols| × |usedRows|` equal cells, **not** `shape.cols × shape.rows`.
4. Each window's span is mapped from absolute `(col, row)` indices to *used*
   indices: e.g. if `usedCols = {0, 2}` and a window has `col0=2, col1=2`,
   it maps to used-col index `1` of `2`. The window then occupies the
   corresponding cell rectangle.

This gives the "if a column or row is empty, the others grow" behaviour
without storing per-cell weights or doing any tree gymnastics.

Inner gaps are applied between *used* cells only, matching the visual
expectation of "fewer cells means bigger cells."

## New-window placement heuristic

When a window opens that is **not** in `WindowMemory` and **not** matched
by an explicit float rule, mur picks a span:

1. Compute `usedCols` for the workspace (as above).
2. **Empty workspace**: place the new window at the centre column,
   spanning all rows. (For a 3×3, that's `col=1, rows=0..2`.)
3. **One column in use** (call it `c*`):
    - If a fully-empty column exists adjacent to `c*` (i.e. `c*-1` or
      `c*+1` has zero windows touching it), place the new window there,
      single-column, full row span.
    - Prefer the side with more empty space. Tiebreak: right.
4. **Multiple columns in use, but a fully-empty column exists somewhere**:
   place the new window in the empty column nearest to the focused window's
   column, full row span.
5. **No empty column available**: place the new window in the **middle
   column** (`shape.cols / 2`), full row span. It will overlap whatever's
   already there. Z-order: top.

When a window opens that **is** in `WindowMemory`, mur uses the stored
span verbatim (clamped to the current `shape` if the layout changed). The
heuristic above is skipped.

## Mouse-driven resize

Mur preserves AeroSpace's "drag any edge, the layout follows" feel —
this is one of AeroSpace's best UX details and we keep the trigger and
edge-diff approach untouched. Only the *commit* changes.

### Tiled windows

1. AX fires `kAXResizedNotification`. The existing `resizedObs` handler
   (`mouse/resizeWithMouse.swift`) checks `isManipulatedWithMouse` and
   schedules a light session — unchanged.
2. Inside the session: compare `window.getAxRect()` (current pixel rect
   the user has dragged to) against `window.lastAppliedLayoutPhysicalRect`
   (the rect mur last drew). The pixel deltas tell us which edges moved
   and by how much. This is identical to AeroSpace's logic.
3. **New**: instead of mutating tree-node weights, build a
   `GridResize.DragSample` and call `GridResize.snap(...)`. The snapper:
    - Determines which edges the user dragged (epsilon-tolerant).
    - Maps each dragged edge to the nearest **visible-cell boundary** in
      `available` — this is the post-collapse pixel grid, so dragging
      "feels" right even when empty rows/cols have collapsed and visible
      cells are bigger than absolute cells.
    - Translates the visible-cell boundary back to an absolute (col, row)
      index using `usedCols` / `usedRows`.
    - Returns a clamped `TileSpan`.
4. Commit: `GridLayout.place(windowId, at: snapped)` and
   `WindowMemory.remember(...)`. A refresh re-renders.

The user therefore drags freely (pixel-level, just like AeroSpace), and
on release (or live, depending on how aggressively we re-snap) the
window snaps to the nearest valid `TileSpan`. Strict tile positioning is
preserved without sacrificing the AeroSpace feel.

### Floating windows

Untouched. Floats keep their free-form pixel resize, exactly as in
AeroSpace, including `lastFloatingSize` for restore-on-unfloat.

### What gets deleted

- `adaptiveWeightBeforeResizeWithMouseKey` and the per-tree-node
  weight-before-resize cache.
- `getWeightBeforeResize`, `resetResizeWeightBeforeResizeRecursive`.
- The four-way `closestParent(hasChildrenInDirection:withLayout:)` walk.
- `Orientation.getDimension` weight-axis logic.

`currentlyManipulatedWithMouseWindowId`, `isManipulatedWithMouse`,
`resizedObs` — all kept.

## Workspace state machine (replaces the tree)

```
Workspace
  ├── layout: GridLayout                 // single, no nesting
  ├── floats: [WindowId]                 // unchanged from AeroSpace
  └── shims: macOS native fullscreen / minimised / hidden / popup containers
```

The shim containers (`MacosFullscreenWindowsContainer`, etc.) stay — they
exist for OS bookkeeping, not user-visible layout.

## Migration plan

This is a **multi-PR** change. Doing it in one commit would break every
test, command, and integration in the repo simultaneously.

### Phase 0 — design + scaffolding (this PR)

- [x] `docs/MUR_DESIGN.md` (this file).
- [x] New types: `GridShape`, `TileSpan`, `GridLayout`, `WindowMemory`.
      Pure value/data types, no wiring yet.
- [x] README rebrand to "mur".
- [ ] Tests for `TileSpan` invariants and the collapse algorithm.

### Phase 1 — parallel layout

- Add `Workspace.gridLayout: GridLayout` alongside the existing
  `rootTilingContainer`. Don't remove the tree yet.
- New `layoutGrid()` on `Workspace` that ignores the tree if
  `gridLayout.placements` is non-empty. Otherwise falls through to legacy
  `layoutRecursive`.
- Feature flag: `config.experimental_grid_layout = true` enables grid path.

### Phase 2 — command surface

- New commands: `mur grid place <col0> <row0> <col1> <row1>`,
  `mur grid float`, `mur grid focus <col> <row>`, `mur grid swap <dir>`.
- Deprecate (alias to no-op or grid equivalent): `split`, `layout tiles`,
  `layout accordion`, `join-with`, `move` (replaced by grid-aware move).
- Window-memory persistence: load on launch, write on placement change.

### Phase 3 — tree removal

- Delete `TilingContainer`, `Layout` (the enum), `Orientation`, the BSP
  normalisation logic, `splitCommand`, `joinWithCommand`, the
  `accordion`/`tiles` config keys.
- Collapse `TreeNode` to `Workspace | Window | shim` — no more
  `NonLeafTreeNodeObject` polymorphism.
- Update tests. Remove `bobko/`-prefixed long-lived branches' relevance
  from CI.

### Phase 4 — additional grid shapes

- Config: `mur.layouts = ["3x3", "2x2", "1x3"]` plus a default.
- `mur layout next` / `mur layout <name>` to switch the active grid.
- Window-memory keyed by `(shape, appId, title)` so memory survives
  layout switches per-shape.

## What stays the same

- AeroSpace's monitor handling, workspace switching, multi-monitor logic.
- Floating windows (now strictly opt-in via float rules or the
  `mur grid float` command).
- macOS native fullscreen / minimised / popup shim containers.
- The CLI/daemon split (`mur` CLI talks to the `mur` app over a Unix socket).
- Config file location and format (TOML), minus the layout-tree keys.
- SIP-free operation. No new entitlements.
