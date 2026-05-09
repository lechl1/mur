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
2. **Predefined grids.** The first (and only initial) layout is a **3×3 grid**.
   Future layouts (2×2, 1×3, 1×2, 4×3, etc.) plug in behind the same protocol.
3. **Tiles, not splits.** A grid has fixed cell *coordinates*. A window's
   geometry is described as a **tile span** — a contiguous rectangle of cells
   `(col0..col1, row0..row1)`.
4. **Stacking is first-class.** Multiple windows can occupy overlapping spans.
   Z-order is explicit. This is what AeroSpace's tree paradigm cannot express.
5. **Empty rows/cols collapse.** If a row or column has zero windows touching
   it, it contributes 0 to the layout, and the remaining rows/cols expand to
   fill. At least one cell is always occupied per workspace (enforced when the
   workspace has ≥1 tiled window).
6. **Floating still works.** A window can opt out of the grid entirely and
   float, exactly as in AeroSpace.
7. **Sticky placement memory.** When a known window (matched by app id +
   window title) opens, it reuses its last-known tile span. Otherwise the
   placement heuristic chooses one.

## Non-goals

- BSP / accordion / dwindle / column / row layouts from i3 or AeroSpace.
- Resize-by-pixel of individual tiles. Tiles are **structural**, not pixel-resizable.
  (You change the grid by *changing the layout*, not by dragging gutters.)
- Per-tile gaps that differ from per-grid gaps.

## Core types

### `GridShape`

A grid is `(cols: Int, rows: Int)` with `cols ≥ 1` and `rows ≥ 1`.
The default layout is `GridShape(cols: 3, rows: 3)`.

### `TileSpan`

```
struct TileSpan {
    let col0: Int   // inclusive, 0..<cols
    let row0: Int   // inclusive, 0..<rows
    let col1: Int   // inclusive, col0..<cols
    let row1: Int   // inclusive, row0..<rows
}
```

Invariants: `0 ≤ col0 ≤ col1 < shape.cols` and same for rows. Spans are
always axis-aligned rectangles. A "single-tile" placement is `col0 == col1
&& row0 == row1`. Spans **may overlap** other windows' spans.

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
