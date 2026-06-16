# HopUI Architecture

HopUI is a native-Swift, demand-driven SwiftUI implementation for the **desktop** (macOS, Windows,
Linux). It compiles with the official Swift toolchain and renders through native widget toolkits.
The cross-platform toolkit is **GTK4** (one toolkit that runs on all three OSes via its C ABI); an
**AppKit** toolkit (macOS) and a **WinUI 3** toolkit (Windows) are included to prove the multi-toolkit
seam against genuinely different native frameworks.

> **The central problem.** Desktop toolkits are *retained-mode*: a `GtkButton`/`NSButton` is a dumb
> object you create once and mutate imperatively. A declarative SwiftUI surface needs two things on
> top of that: (1) a reactive engine that tracks which views read which state, so a change can
> recompute the minimum, and (2) declarative reconciliation that diffs a re-described view tree into
> the minimal set of mutations on the retained widgets. HopUI builds both itself — an
> **AttributeGraph** (the reactive engine) and a **Reconciler** (the declarative diff) — while
> keeping the authoring surface (`View`, `@State`, `@ViewBuilder`) identical to SwiftUI.

## Layers

```
User SwiftUI code  →  View + @ViewBuilder  →  ViewGraph  →  AttributeGraph  →  DisplayList  →  RenderToolkit  →  native widgets
```

| Layer | Module | Role |
|-------|--------|------|
| `View` / `@ViewBuilder` / `@State` | `HopUI` | SwiftUI-mirroring authoring surface |
| ViewGraph + evaluation | `HopUI` | walks the view tree into a `RenderNode` tree, reading `@State` |
| AttributeGraph | `HopGraph` | demand-driven reactive core: pull-based eval, dynamic edges, dirty propagation |
| DisplayList (`RenderNode`) | `HopUI` | toolkit-agnostic value-type render tree keyed by identity |
| Reconciler | `HopUI` | diffs successive `RenderNode` trees → minimal toolkit ops |
| `RenderToolkit` | `HopUI` | the multi-OS seam (create/configure/insert/remove/setAction) |
| GTK4 / AppKit / Qt / WinUI toolkits | `HopGTK4`, `HopAppKit`, `HopQt`, `HopWinUI` | translate ops to native widgets + run the platform loop |
| GTK4 / Qt C ABI shims | `CGTK4`, `CQt` | hand-rolled C(++) shims over `gtk/gtk.h` and Qt6 |

## AttributeGraph (`HopGraph`)

A demand-driven dependency graph modeled on the kind of attribute graph that backs SwiftUI itself.

- **Nodes** are *sources* (mutable inputs — the backing for `@State`) or *rules* (closures deriving
  a value from other attributes).
- **Pull-based + memoized:** `read` returns the cached value if valid; otherwise it recomputes,
  caches, and returns.
- **Dynamic edge discovery:** while a rule evaluates, a thread-local "current attribute" records an
  edge for every attribute it reads. Edges are rebuilt each evaluation, so a dependency that an
  `if` omits on a given run is correctly dropped.
- **Invalidation:** writing a source flips everything transitively downstream to `pending` *without
  recomputing*; the recompute happens lazily on the next read.

This is the reactive substrate a retained-mode toolkit does not provide. The MVP is single-threaded
(UI-thread) and uses a single root render rule; per-view-body attributes and lifetime *subgraphs*
are the next refinement (see Roadmap).

## Reconciler + RenderToolkit (`HopUI`)

Evaluation produces a `RenderNode` tree (`id`, `kind`, `WidgetPatch`, `children`, `action`). The
`Reconciler` keeps a map of `id → native handle` and diffs new vs. previous by structural identity,
calling only the `RenderToolkit` operations needed (a `configure` for a changed label, no
`makeWidget` for unchanged nodes). The `RenderToolkit` protocol is pure value-types plus an opaque
`Handle`, so no GTK/AppKit type appears above the toolkit module — that is what makes toolkits
pluggable.

Event flow: a native click invokes the stored Swift `action` → mutates `@State` → `Graph.setValue`
marks the render rule dirty → a flush re-pulls the tree → the reconciler applies the minimal native
mutation.

## Toolkits

- **GTK4 (`HopGTK4` + `CGTK4`)** — the cross-platform toolkit. `CGTK4` is a `systemLibrary` whose
  `module.modulemap` wraps a `shim.h` that `#include`s `<gtk/gtk.h>` and exposes a thin
  `void *`-based C surface (keeping the `GTK_*()` cast macros and `g_signal_connect` plumbing on the
  C side). Include/link flags come from `pkg-config gtk4`, which resolves identically on macOS
  (brew), Linux (apt), and Windows (MSYS2). Widgets map to `GtkBox`/`GtkLabel`/`GtkButton`; the app
  runs a `GtkApplication` loop.
- **AppKit (`HopAppKit`)** — macOS-native, guarded by `#if canImport(AppKit)`. Maps to
  `NSStackView`/`NSTextField`/`NSButton` with a target/action trampoline; runs `NSApplication`.
- **Qt (`HopQt` + `CQt`)** — Qt has no C ABI, so `CQt` is a **C++** target that `#include`s
  QtWidgets and exposes a pure-C surface (`CQt.h`); Swift imports only that C header, never Qt's
  C++ types. Maps to `QVBoxLayout`/`QHBoxLayout`/`QLabel`/`QPushButton`/`QLineEdit`; signals are
  wired once with `QObject::connect` + a capturing lambda (no `moc` step). Runs `QApplication`.
  Added to the package only on macOS (`#if os(macOS)` in `Package.swift`), linking Homebrew Qt6
  frameworks via `-F`; the same shim approach extends to Qt on Linux/Windows by swapping the flags.
- **WinUI 3 (`HopWinUI`)** — the Windows-native toolkit. It binds real WinUI 3 XAML controls through
  the [`swift-winui`](https://github.com/hoptools/swift-winui) WinRT projections (generated by
  thebrowsercompany's `swift-winrt`), mapping HopUI widgets onto
  `TextBlock`/`Button`/`TextBox`/`PasswordBox`/`ToggleSwitch`/`Slider`/`ComboBox`/`ListView`/
  `ProgressBar`/`Image` and drawing shapes with `Microsoft.UI.Xaml.Shapes.Path` geometry. Every
  container is a `Canvas` so HopUI's layout engine owns all geometry (absolute placement via
  `Canvas.SetLeft`/`SetTop`). The app enters through a `SwiftApplication` subclass (the Windows App SDK
  owns the XAML/Win32 message loop); Swift Concurrency runs on that loop via `DispatchQueue.main` (which
  swift-winui's run-loop tickler drains), and `@Observable`/`@State` re-renders are coalesced onto it.
  Added to the package only on Windows (`#if os(Windows)` in `Package.swift`), and requires a matching
  Windows App Runtime at launch.

## MVP simplifications (and the road past them)

The current code is the **walking skeleton** that proves the architecture end to end. Deliberate
simplifications, each with a clear upgrade path:

1. **Native containers do layout.** The MVP uses `GtkBox`/`NSStackView`. The blueprint's
   geometry-owning layout engine (parent-proposes/child-chooses modeled as attributes, absolute
   placement in `GtkFixed`) replaces this — it is what keeps layout identical across toolkits.
2. **Single root render rule.** All state feeds one render attribute; the reconciler still minimizes
   *widget* mutations. Per-view-body attributes will make *recompute* incremental too.
3. **Synchronous flush.** State writes flush immediately. A frame-batched flush (`g_idle_add` /
   `CFRunLoopPerformBlock`) will coalesce.
4. **Structural identity only.** `.id(_:)` and `ForEach` keyed identity are next.
5. **Snap, no animation.** The transaction/provenance ledger is designed but not wired.

## Roadmap

1. Geometry-owning layout pass (proposals/sizes/frames as attributes; `GtkFixed`).
2. Per-`ViewNode` subgraphs with lifetime teardown; fine-grained invalidation.
3. Widget breadth: `Toggle`, `Slider`, `TextField`, `Picker`, `List`, `ScrollView`, `Image`;
   `Color`/`Font`/`Shape` (via `GtkDrawingArea` + Cairo).
4. `Environment`, `@Binding` to nested state, `ForEach` identity, animations.
5. Cross-OS hardening (Linux apt, Windows MSYS2); the AppKit and WinUI 3 toolkits are the real seam test.
