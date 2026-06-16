# HopUI

A native-Swift, cross-platform **desktop** SwiftUI implementation with its own demand-driven
AttributeGraph and a pluggable render toolkit. The cross-platform toolkit is **GTK4** (macOS,
Windows, Linux); **AppKit** (macOS), **Qt**, and **WinUI 3** (Windows) toolkits are included to
demonstrate the multi-toolkit seam against genuinely different native frameworks.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## Layout

| Module | Purpose |
|--------|---------|
| `HopGraph` | Demand-driven (pull-based) AttributeGraph — the reactive core. No UI/GTK deps. |
| `HopUI` | SwiftUI-mirroring API (`View`, `@State`, `VStack`/`HStack`/`Text`/`Button`), view-graph evaluation, `DisplayList`, `Reconciler`, and the `RenderToolkit` seam. |
| `CGTK4` | Hand-rolled C module over the GTK4 C ABI (resolved via `pkg-config gtk4`). |
| `HopGTK4` | GTK4 toolkit + `GtkApplication` runtime. |
| `HopAppKit` | AppKit toolkit (macOS only). |
| `CQt` / `HopQt` | C++ shim over Qt6 (pure-C surface) + Qt toolkit (macOS, via Homebrew Qt). |
| `HopWinUI` | WinUI 3 toolkit (Windows) — binds real XAML controls via the [`swift-winui`](https://github.com/hoptools/swift-winui) WinRT projections. |
| `HopDemo` | Shared `ContentView` used by every toolkit demo. |

## Prerequisites

- Swift 6.1+
- GTK4 (only for the GTK4 toolkit/demo):
  - macOS: `brew install gtk4 pkg-config`
  - Linux: `apt install libgtk-4-dev pkg-config`
  - Windows: MSYS2 `mingw-w64-x86_64-gtk4 mingw-w64-x86_64-pkgconf` (set `PKG_CONFIG_PATH`/`PATH` to the mingw64 prefix)
- Qt6 (only for the Qt toolkit/demo, macOS): `brew install qt`
- WinUI 3 (only for the WinUI toolkit/demo, Windows):
  - the [`swift-winui`](https://github.com/hoptools/swift-winui) projections checked out next to this
    repo (`../swift-winui` — `Package.swift` references it as a path dependency)
  - a Windows SDK (any version ≥ 10.0.17763) — present on standard Windows dev installs
  - the matching Windows App Runtime installed to *run* the demo, e.g.
    `winget install --id Microsoft.WindowsAppRuntime.1.6 --force`

## Build, test, run

```bash
swift test                              # core (HopGraph + HopUI) — no GTK/Qt required
swift run hop-demo-gtk4                  # the GTK4 demo window
swift run hop-demo-appkit                # the AppKit demo window (macOS)
swift run hop-demo-qt                    # the Qt demo window (macOS, Homebrew Qt)
HOP_TOOLKIT=winui swift run hop-demo-winui   # the WinUI 3 demo window (Windows)
```

Equivalent helper scripts live in `scripts/` (`run-gtk4.sh`, `run-appkit.sh`, `run-qt.sh`,
`build.sh`). Every demo renders the identical `CounterView` through the same HopGraph/HopUI core —
run them side by side to compare toolkits. Clicking a button or typing in the text field mutates
`@State`, which flows through the attribute graph and reconciler to update the dependent views.
