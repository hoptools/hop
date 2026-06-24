# Design Plan: `Grid`, `LazyVGrid`, `LazyHGrid` for HopUI

## 0. Scope & guiding facts

Implement the full SwiftUI grid family, faithfully:

- **`Grid` / `GridRow`** (iOS 16+/macOS 13+) — a **non-lazy**, column-*aligned* 2D layout (a "table"): every column is sized to the widest cell in that column across all rows. Must measure all cells (cannot virtualize — that's its defining semantic).
- **`LazyVGrid(columns:)` / `LazyHGrid(rows:)`** (iOS 14+/macOS 11+) — **lazy**, track-based flow inside a `ScrollView`; only visible cells are materialized. This is the path for *arbitrarily large* content.
- **`GridItem`** track descriptors `.fixed` / `.flexible` / `.adaptive`, with per-item `spacing`/`alignment`.
- Cell modifiers `.gridCellColumns`, `.gridCellAnchor`, `.gridColumnAlignment`, `.gridCellUnsizedAxes`; `pinnedViews` (sticky section headers/footers).

### Decisive architectural insight
**Grids are 100% framework-side — NO per-backend (AppKit/GTK/Qt/WinUI) code.** The `LayoutEngine` (toolkit-agnostic) already sizes/positions any child via `setFrame`, exactly as it does for `VStack`/`LazyVStack`. A grid is just a new *role* with a 2D size/place algorithm; cells are ordinary leaf/container widgets the engine positions. The lazy grids reuse the existing `ScrollView` + `ForEach` + virtualization machinery (`ScrollContextStore`, per-identity graph sources, `forEach.forEachChild(at:)`, `lazyIndex`). This makes the whole feature single-target (HopUI core), like `@AppStorage`.

### Terminology (used consistently below)
A **line** is one band of K cells: a *row* in LazyVGrid (K columns), a *column* in LazyHGrid (K rows). A **track** is one column (LazyVGrid) or row (LazyHGrid). "Main axis" = scroll axis; "cross axis" = the track axis.

### Efficiency contract (the "arbitrarily large / optimal" requirement)
- **`LazyVGrid`/`LazyHGrid`: strictly O(visible cells)** — *for `RandomAccessCollection` data* (Array, Range — what `ForEach` and the demos use). Items flow `index → (line = i / K, track = i % K)`; only the **visible line band** (± buffer) is materialized via `forEach.forEachChild(at:)`. NOTE: `ForEach.forEachChild(at:)` uses `index(_:offsetBy:)`, which is O(1) for `RandomAccessCollection` but O(offset) otherwise — so the O(visible) guarantee requires `ForEach<Data: RandomAccessCollection>` (already the contract for `LazyVStack`). A 1,000,000-item Array grid builds ~`viewport/lineHeight × K` widgets.
- **`Grid`: O(cells)** by SwiftUI design (column alignment requires measuring all cells). For bounded, column-aligned content; large/complex stress demos use the lazy grids.
- **No NEW backend code.** Cells are measured through the *existing* `RenderToolkit.measureComponent` and positioned via the *existing* `setFrame` — the same toolkit surface `VStack`/`LazyVStack` already use. No new toolkit protocol methods, no per-OS shims. "Framework-side only" = HopUI core (`LayoutEngine` + views + virtualization).
- Incremental: the engine's measure-cache (keyed by `subtreeRevision`) skips unchanged cells; the reconciler's keyed child diff reuses cell widgets across scrolls (insert/move/remove) so scrolling recycles, not rebuilds.

---

## 1. Public API surface (the full feature checklist)

All signatures match Apple's so the Showcase dual-compiles against real SwiftUI.

### Grid
```swift
Grid(alignment: Alignment = .center,
     horizontalSpacing: CGFloat? = nil,
     verticalSpacing: CGFloat? = nil,
     @ViewBuilder content: () -> Content)

GridRow(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content)
```
Behaviors: column width = max cell width across rows · row height = max cell height in row · cells fill their (colWidth × rowHeight) cell by default · a view placed loosely (not in a `GridRow`) spans the full grid width · ragged rows leave trailing cells empty but column-aligned.

### Cell / column modifiers (View extensions)
```swift
.gridCellColumns(_ count: Int)                       // span N columns (width = sum of those columns; columns not widened)
.gridCellAnchor(_ anchor: UnitPoint)                 // position content within the cell (after fill decisions)
.gridColumnAlignment(_ guide: HorizontalAlignment)   // sets H-alignment for the WHOLE column the cell is in
.gridCellUnsizedAxes(_ axes: Axis.Set)               // do NOT expand to fill the cell on these axes (use intrinsic)
```

### LazyVGrid / LazyHGrid
```swift
LazyVGrid(columns: [GridItem], alignment: HorizontalAlignment = .center,
          spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = .init(),
          @ViewBuilder content: () -> Content)
LazyHGrid(rows: [GridItem], alignment: VerticalAlignment = .center,
          spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = .init(),
          @ViewBuilder content: () -> Content)
```

### GridItem
```swift
struct GridItem {
  enum Size { case fixed(CGFloat); case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
              case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity) }
  var size: Size; var spacing: CGFloat?; var alignment: Alignment?
  init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil)
}
```
`PinnedScrollableViews` = an OptionSet (`.sectionHeaders`, `.sectionFooters`).

---

## 2. Core types & wiring (HopUI core)

| Addition | File | Purpose |
|---|---|---|
| `WidgetRole.grid/.gridRow/.lazyGrid` (public) **AND** matching `LayoutRole` cases (internal) **AND** `role(of:)` mapping | Component.swift + Layout.swift + LayoutEngine.swift `role(of:)` | **all three updated in lockstep** — there are two enums (public `WidgetRole`, internal `LayoutRole`) bridged by `role(of:)`; the critique flagged that adding only `WidgetRole` is insufficient |
| `.grid` = non-lazy column-aligned; `.gridRow` = a marker the grid positions through; `.lazyGrid` = virtualized track flow | — | layout dispatch |
| `GridComponent`, `GridRowComponent`, `LazyGridComponent` | new `Grid.swift` | `WidgetComponent`s carrying the configs; `.grid`/`.gridRow`/`.lazyGrid` `WidgetKey`s |
| `GridConfig` { alignment, hSpacing, vSpacing } · `LazyGridInfo` { axis, columns:[GridItem], alignment, itemSpacing, lineSpacing, totalCount } | Grid.swift | layout inputs |
| RenderNode fields: `gridCellColumns: Int?`, `gridColumnAlignment: HorizontalAlignment?`, `gridCellAnchor: UnitPoint?`, `gridCellUnsizedAxes: Axis.Set?` | Render.swift | per-cell metadata. **MUST also** be added to `hasWrapperState` (`\|\| gridCellColumns != nil \|\| …`) and `applyWrapperState` (transfer from ref) — else modifiers on a composite cell don't propagate (the critique confirmed `hasWrapperState` doesn't auto-include new fields). |
| `LayoutInfo.lazyGridIndex: LazyGridIndex?` (struct `{ line: Int; track: Int }`) + a new `placeLazyGrid` | Layout.swift + LayoutEngine.swift | `LayoutInfo.lazyIndex` is a 1-D `Int?` and `placeLazyStack` assumes a single column, so 2-D needs its own index + place path (do NOT overload the 1-D one). |
| `Grid`, `GridRow`, `LazyVGrid`, `LazyHGrid` views; `GridItem`; `Axis.Set`; `PinnedScrollableViews` | Grid.swift | public API |
| `_GridCellColumnsModifier`, `_GridColumnAlignmentModifier`, `_GridCellAnchorModifier`, `_GridCellUnsizedAxesModifier` | Modifiers.swift | the `.tag`/`.tabItem` metadata-stamping pattern (PrimitiveView → evaluate content → mutate first node's field → return) |

No `WidgetPatch` change (cell metadata are direct RenderNode fields, like `tag`/`tabLabel`). No backend changes.

**Reuse signature (decided — was flagged a blocker):** `RenderNode.reuseSignature` is `widgetKey`-only, so a runtime `.gridCellColumns` change at the same cell id would wrongly reuse the widget. **Fix: extend `reuseSignature` to append the cell's grid metadata** → `"c:\(widgetKey.rawValue)|span:\(gridCellColumns ?? 1)"`. (Span changes are rare but must recreate; the other cell metadata only affect placement, not the widget, so span alone suffices.)

---

## 3. `Grid` layout algorithm (non-lazy)

Runs entirely in `LayoutEngine.sizeCore(.grid)` + `place(.grid)`. The grid node's children are `GridRow` nodes (role `.gridRow`) and/or loose nodes. The engine doesn't auto-descend, so the grid logic explicitly reads `row.children` for cells (one level of unwrap).

This is a **two-pass measure → place**, not a circular dependency: pass 1 measures cells at their *intrinsic* size to derive column widths/row heights; the place pass then *proposes each cell its final cell rect* (the cell sizes itself to that proposal, exactly as `stackLayout` proposes children). A cell's column index = running sum of prior spans in its row (cell N occupies column `Σ spans[0..<N]`).

**Sizing (sizeCore):**
1. Partition children into lines: each `.gridRow` → its `children` are cells (assign columns by cumulative span); each loose child → a single full-span line.
2. **Measure (intrinsic):** every cell with `ProposedViewSize(nil,nil)` → record `(width, height, span = gridCellColumns ?? 1, firstCol)`.
3. **Column widths.** `columnCount = max over lines of (Σ spans)` (a line with more cells simply defines more columns; shorter lines leave trailing columns empty but width-reserved). For column `c`, `width[c] = max over lines of {cell.width | cell at column c with span == 1}`. Spanning cells do **not** widen columns (SwiftUI); a column whose only contributors span gets a floor of `max(ceil(spanWidth / span))`.
4. **Row heights.** `height[r] = max cell height in line r` (including any loose child's intrinsic height).
5. Grid size = `Σ width + (columnCount-1)·hSpacing` × `Σ height + (rowCount-1)·vSpacing`. Column widths are content-driven (no flexible distribution); outer constraint comes from `.frame` on the Grid. `GridItem.spacing` does NOT apply to `Grid` — only the global `horizontalSpacing`/`verticalSpacing` do (`GridItem.spacing` is a LazyVGrid/LazyHGrid concept).

**Placement (place):**
- Precompute column X offsets `colX[c] = Σ_{j<c}(width[j]+hSpacing)` and row Y offsets.
- Place each `GridRow` node at `(0, rowY, gridWidth, height[r])`; place each cell *relative to its row* at:
  - cell rect = `(colX[firstCol], 0, spanWidth, height[r])` where `spanWidth = Σ width over spanned cols + (span-1)·hSpacing`.
  - **Fill vs intrinsic:** by default the cell is *proposed* its cell rect (it fills). `gridCellUnsizedAxes` → on listed axes, use the cell's intrinsic extent and position via alignment instead of stretching.
  - **Alignment:** within the cell rect, apply (in order) the column's H-alignment (`gridColumnAlignment`, default from `Grid.alignment.horizontal`), the row's V-alignment (`GridRow(alignment:)`, default `Grid.alignment.vertical`), then `gridCellAnchor` (UnitPoint) overrides both if present.
- **GridRow placement:** `placeCore(.grid)` calls `setFrame(gridRowNode, (0, rowY, gridWidth, height[r]))` (grid-local coords), THEN `place(cell, cellRect)` where `cellRect` is relative to the GridRow origin — matching the `stackLayout` pattern (set the container frame, place children in local space).
- **Loose child:** spans full width; rect = `(0, rowY, gridWidth, height[r])`. Like any cell it's *proposed* that rect (a divider with a fixed height won't stretch vertically because it returns its own height; a flexible view fills). `gridCellUnsizedAxes` controls stretch explicitly.

**Edge cases:** ragged rows (a line with N<columnCount cells → trailing columns reserved/empty, alignment preserved); a row with MORE cells just widens `columnCount`; empty Grid; single loose child; a column whose only cells span. (`.gridCellColumns(0)`/negative are clamped to 1; documented as undefined like SwiftUI.)

---

## 4. `LazyVGrid` / `LazyHGrid` (lazy, virtualized)

LazyVGrid = vertical scroll, K **column** tracks; LazyHGrid = horizontal scroll, K **row** tracks. Below uses LazyVGrid terms (transpose for H). Mirrors `LazyVStack`'s contract: **content must be a single `ForEach`** (the `AnyForEach` shape) for virtualization; otherwise fall back to eager (still correct, just not lazy).

### 4a. Track resolution (`[GridItem]` → concrete tracks)
Given available cross width `W` **read from the enclosing `ScrollContext` viewport** and inter-track spacing. **Convergence (chicken-and-egg):** `W` comes from the ScrollView's `onGeometry` feedback (a graph source the LazyVGrid reads), so on the very first pass `W` is the default/full width and `K` may be provisional; after the geometry callback fires, the LazyVGrid re-evaluates (it depends on the viewport source) and re-resolves `K` — identical to how `LazyVStack`'s row-extent converges (hence tests need 2× `drainMainThread`). **Responsive reflow:** because `W` is a tracked dependency, a window resize re-fires `onGeometry` → re-resolve `K` → items re-flow (`item i → (i/K', i%K')`) → re-materialize. No manual invalidation needed.
1. Sum fixed widths + spacings into `used`; `free = W - used`.
2. `.adaptive(min,max)`: a single GridItem expands into `n = max(1, floor((slot + s)/(min + s)))` equal sub-tracks, each `clamp((slot-(n-1)s)/n, min, max)`. (`slot` = this item's share; for all-adaptive grids, slot = full free width.)
3. `.flexible(min,max)`: the remaining `free` after fixed+adaptive is split equally among flexible items, each `clamp(share, min, max)`; leftover from clamping redistributes once.
4. Produce the final ordered list of track widths `tracks[0..<K]` and their X offsets. `K` is dynamic for adaptive (drives responsive reflow).

> The exact SwiftUI mixed-mode algorithm is undocumented; this is a faithful, deterministic approximation. The common single-mode cases (all-flexible, all-fixed, all-adaptive) match SwiftUI exactly.

### 4b. 2D virtualization (extends the 1D LazyVStack mechanism)
Reuse verbatim: `ScrollContextStore.current` (viewport + offset), per-identity `extentSource` (line-height estimate, default 44), `originSource` (the grid's offset within scroll content), `onRowExtent`/`onContentOrigin`, and `forEach.forEachChild(at:)`.

1. Resolve tracks → `K`.
2. `lineStride = lineHeight + lineSpacing`; `totalLines = ceil(count / K)`.
3. Visible band: `firstLine = max(0, floor((offset - origin)/lineStride) - buffer)`, `lastLine = min(totalLines-1, floor((offset - origin + viewport)/lineStride) + buffer)`.
4. Materialize only `index ∈ [firstLine·K, (lastLine+1)·K)` (clamped to `count`): for each such `index`, `forEach.forEachChild(at: index)` → evaluate → stamp `LazyGridIndex(line: index/K, track: index%K)`.
5. **Place (engine `.lazyGrid` → `placeLazyGrid`):** cell rect = `(trackX[track], line·lineStride, trackWidth[track], lineHeight)`. Per-cell alignment: the cell's `GridItem.alignment` (if set) overrides the grid's default `alignment`, applied within the track rect. Report the **max line height across the visible band** via `onRowExtent` (NOT just the first row — the critique found `placeLazyStack` only reports the first, which under-estimates for variable heights) so the estimate converges to a representative line height.
6. **`sizeOf` / content extent:** the grid reports its full main-axis extent `totalLines·lineStride - lineSpacing` (× cross = `Σ tracks`) so the `ScrollView` scrollbar/over-scroll is correct even though only the band exists.

### 4c. Variable-height cells
Line height = max cell height in that line. The uniform `extentSource` estimate is fine for roughly-uniform cells; the "complex content" stress demo (variable heights) is handled by: (a) `onRowExtent` feeding back the *current band's* line height, and (b) a refinement (Phase 2.5): a small per-line measured-height cache so wildly variable lines don't under-materialize. Documented limitation if heights vary by >2–3×.

---

## 5. `pinnedViews` (sticky section headers/footers) — Phase 4 (largest, deferred)

`LazyVGrid(pinnedViews: .sectionHeaders) { Section { ... } header: { ... } }`. **Bigger than first scoped: HopUI has no `Section` view at all today** (the List has sectioned data, but there's no general `Section` container). So this requires THREE sub-tasks: (1) add a general `Section` view/component; (2) teach the lazy grid to recognize `Section` children, lay each section's items as a sub-band, and track section header/footer indices; (3) add a "sticky" placement flag the engine honors — clamp a pinned header's main-axis position to `max(sectionTop, viewportEdge)` while its section is in view, releasing when the next header reaches the edge. This is its own milestone (Phase 4). The lazy grids ship fully functional without it; until then a `Section` inside a LazyVGrid is treated as a plain content container (its header/footer render inline, not pinned) — documented.

---

## 6. Demos — new "Grid" sidebar category

A `SidebarSection(id: "grid", title: "Grid")` placed after "Containers", with playgrounds (each dual-compiles vs Apple SwiftUI):

1. **`gridTable`** — `Grid`/`GridRow`: a column-aligned table (labels + values across rows) showing automatic column alignment; includes `.gridColumnAlignment`, a `.gridCellColumns(2)` spanning header, and a loose full-width divider.
2. **`gridLazyLarge`** — `LazyVGrid(columns: [GridItem](repeating: .flexible(), count: 4))` over **`ForEach(0..<10_000)`** of simple cells in a `ScrollView` — proves virtualization (smooth scroll, bounded widget count).
3. **`gridLazyComplex`** — `LazyVGrid` of **complex nested cells** (each cell a `VStack` of `Image` + `Text` + `Toggle`/gradient/shape) over a large range — stress-tests layout depth × virtualization.
4. **`gridAdaptive`** — `LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))])` — responsive reflow as the window resizes (column count changes).
5. **`gridLazyH`** — `LazyHGrid(rows:)` in a horizontal `ScrollView` over a large range.
6. **(Phase 3)** `gridSections` — pinned section headers.

Demo helpers mirror `LayoutPlayground` (large `ForEach`) and `ColorPlayground` (nested rows).

---

## 7. Tests (deterministic, MockToolkit)

`GridTests` + `LazyGridTests` (MockToolkit measure is deterministic: label = `len·8+8` wide, 20 tall):

- **Grid column alignment:** rows with different-width cells → assert each cell's `frame.minX`/width equals its column's max-width offset; assert a short cell is column-aligned with a wide cell below it.
- **Spanning:** `.gridCellColumns(2)` → cell width == sum of 2 columns + spacing.
- **Cell alignment/anchor/unsizedAxes:** assert frame placement under each.
- **Loose child spans full width.**
- **LazyVGrid virtualization (the key one):** `LazyVGrid(4 cols) { ForEach(0..<10_000) }` in a `ScrollView`; after `runHopApp` + 2×`drainMainThread()` (viewport-feedback convergence), assert `toolkit.widgets.filter { $0.kind == .label }.count` is bounded (≪ 10,000, ~`visibleLines·4 + buffer`), and that index 9,999's widget does **not** exist.
- **Complex-content stress (explicitly requested):** `LazyVGrid { ForEach(0..<10_000) { … nested VStack/Image/Text/shape … } }` → assert `toolkit.widgets.filter { $0.kind == .vstack }.count` is bounded (not ~10,000) — proves virtualization holds with deep cells.
- **Content extent for scrollbar:** grid node frame main-extent == `ceil(count/K)·lineStride - lineSpacing`.
- **Recycle on scroll:** drive `onScroll` to a lower offset, drain, assert top cells gone + new cells present (`makeCount` bounded — recycle not rebuild).
- **Adaptive reflow (concrete):** `LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))])`; resize the viewport by firing `onGeometry` 800→400, drain → assert cells-per-line drops (~6→~3).
- **Track resolution unit tests (pure function, exact vs SwiftUI for single-mode):** e.g. `.adaptive(min:120)` in W=500, spacing=10 → `K = floor((500+10)/(120+10)) = 3`, each `(500-2·10)/3 = 160`; `.flexible()` ×3 in W=320, spacing=10 → each `(320-20)/3 = 100`; `.fixed(80)` → 80.
- **MockToolkit note:** grid cells that are `Text` measure deterministically (`len·8+8` × 20); complex cells should be wrapped in `.frame(width:height:)` in tests for deterministic frames.

---

## 8. Phasing

- **Phase 1 — `Grid`/`GridRow` + cell modifiers** (engine 2-pass column-aligned layout; `.grid`/`.gridRow` in WidgetRole+LayoutRole+`role(of:)`; cell metadata fields + hasWrapperState/applyWrapperState + reuseSignature span; `gridTable` demo; column/span/alignment/loose-child tests). Self-contained, fully verifiable.
- **Phase 2 — `LazyVGrid`/`LazyHGrid` + `GridItem`** (track resolution + 2D virtualization: `lazyGridIndex` + `placeLazyGrid` + band-max extent feedback; large/complex/adaptive/H demos; virtualization + complex-stress + reflow + track-resolution tests). The high-value "large content" piece.
- **Phase 2.5 — variable-height refinement.** Hard criterion: if `gridLazyComplex` (variable heights) materializes < the full visible band (detectably under-materializes), add a per-line measured-height cache (keyed by line index in `IdentitySourceStore`) replacing the single uniform estimate. Otherwise skip.
- **Phase 4 — `Section` + `pinnedViews`** (sticky section headers/footers) — its own milestone (needs a general `Section` view first; see §5).

Each phase: build (AppKit/GTK/Qt) + `swift test` + visual verification (`run_demo.sh all gridLazyLarge`) + adversarial review of the diff, per the established workflow.

---

## 8a. Phase 1 — implementation status (DONE)

Phase 1 shipped: `Grid`/`GridRow` + all four cell modifiers, the 2-pass column-aligned engine
(`gridMetrics`/`gridPlaceLayout` in `LayoutEngine.swift`), SwiftUI-faithful **fill** (a greedy child —
`Divider`, un-framed shape, `maxWidth/maxHeight:.infinity` — expands the grid and the surplus is split
equally across the flexible columns/rows), the `gridTable` demo, and 18 `GridTests`. Verified on
AppKit/GTK/Qt + dual-compiled vs SwiftUI; an adversarial multi-agent review was run and its confirmed
findings folded in:

- **Span clamping (was a crash):** a cell's effective `gridCellColumns` is clamped to the grid's total
  cell count (a span past that only invents empty columns), bounding every sum/allocation — so a
  pathological `.gridCellColumns(.max)` can neither overflow `col += span` nor balloon the column arrays.
- **Spanning never widens populated columns:** a spanning cell only reserves a floor for the *empty*
  columns it covers; if all are populated it contributes nothing (content overflows the combined width),
  matching SwiftUI.
- **Non-finite cell sizes sanitized** before entering the column math (a degenerate `.frame(width:.infinity)`
  cell can't poison frames into NaN/∞).
- **`reuseSignature` excludes grid cell metadata** (span only feeds layout, recomputed each pass; it never
  changes the native widget — so a span change reconfigures in place, preserving native state).
- **WinUI backend** registers `.grid`/`.gridRow` (canvas panels) for parity with AppKit/GTK/Qt.

### Fill greediness (post-Phase-1 fix)

A cell is "flexible" (its column/row absorbs the grid's surplus) when it grows along that axis — detected by
`cellFlexible`. Key rules, all matching SwiftUI: a `.frame` that constrains the axis decides it
(`fixed` → rigid, `maxWidth/Height: .infinity` → fills); a `.frame` that touches only the OTHER axis (e.g.
`.frame(height:)`) is transparent, so the content's own greediness still counts — this is why the demo's
blue banner (`RoundedRectangle().frame(height: 36)`) fills horizontally and the grid resizes with the window.
Shapes and (loose) dividers are greedy though their role is `.leaf`. The stack analogue `greedyAlong` was
brought into lockstep (one-axis fall-through + shape greediness + stack recursion) so a shape with a
cross-axis-only frame also fills an HStack/VStack — EXCEPT a `Divider` stays thin on a stack's main axis
(greedy only on its cross axis, via measurement), whereas a grid's *loose* full-span divider is greedy.

### Known Phase-1 limitations (deliberately deferred)

- **minWidth-only / finite-maxWidth cells aren't treated as flexible.** `cellFlexible` only flags
  `maxWidth/Height: .infinity` (or shapes/dividers) as flexible; a cell whose only growth constraint is a
  `minWidth` or a *finite* `maxWidth` is reported rigid, so its column won't absorb surplus (SwiftUI would
  let it grow — minWidth raises the floor, finite max fills up to the cap). Pre-existing; the flexible-track
  model is a `[Bool]`, which can't express capped/min-anchored growth. Fix needs a per-track descriptor
  carrying the min/max cap + clamped redistribution — fold into Phase 2's `GridItem` track sizing.

- **Spanning-cell width is order-dependent for overlapping spans.** The deficit pass is a single forward
  sweep, so when *multiple* spanning cells contend for the *same* empty columns, which span fills a column
  depends on row order. The common cases (single span, spans over disjoint empties, spans over populated
  columns) are order-independent; only overlapping-empty contention diverges. A global/fixed-point column
  solve is the proper fix — fold into a later pass if it ever matters in practice.
- **`Grid` re-measures cells per layout pass (no metrics memo).** `gridMetrics` runs in both `sizeCore`
  and `gridPlaceLayout` and is proposal-independent, so a single layout measures each cell 2–3×. Acceptable
  because `Grid` is **non-lazy / bounded by design** (large content goes to `LazyVGrid`/`LazyHGrid`); add a
  per-flush metrics memo if profiling shows it matters.

---

## 9. Risks & open questions

- **Mixed `GridItem` modes** (fixed+flexible+adaptive together) — SwiftUI's exact algorithm is undocumented; we ship a deterministic approximation and document it. Single-mode is exact.
- **Variable cell heights in lazy grids** — uniform-estimate virtualization can under-materialize; mitigated by `onRowExtent` feedback + Phase 2.5 per-line cache. Documented limit.
- **`ScrollContextStore` is single-slot / non-reentrant** — nesting a lazy grid inside another lazy container is unsupported (same existing constraint as LazyVStack); document it.
- **`Grid` is intentionally non-virtualizing** — must not be used for 10k items; the demos steer large data to LazyVGrid (faithful to SwiftUI).
- **`reuseSignature` is widgetKey-only** — `.gridCellColumns` changes need key/match handling.
- **Grandchild measurement** — Grid measures cells inside `GridRow` (grandchildren); confirmed feasible — `size()`/`place()` are callable on any node and child frames are LOCAL/relative; there's just no existing helper, so `gridSizeLayout`/`gridPlaceLayout` (~100–150 lines) are written fresh.
- **Availability / dual-compile** — `Grid` is iOS 16 / macOS 13+, `LazyVGrid`/`LazyHGrid` iOS 14 / macOS 11+. The Showcase targets `.macOS(.v15)`, so both are available against Apple SwiftUI — the demos dual-compile with no `#available` guards.
- **`Grid` inside a `ScrollView`** — Grid is non-lazy; in a ScrollView it measures all cells and the ScrollView scrolls the overflow (Grid keeps its content-driven width). Add an explicit test for this pattern; it's the main "is the proposal handled right" risk for Grid.
- **`reuseSignature`/`hasWrapperState`/`role(of:)`/`LazyGridIndex`** — all four required plumbing updates are now called out explicitly above (each was a critique blocker that's really "make the plan concrete," not an infeasibility).
