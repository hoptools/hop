// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Every Swift UI target runs on the main actor, so default-isolate them to `MainActor`. This lets
// the code adopt Swift 6 strict concurrency cleanly without scattering @MainActor annotations.
// HopGraph (the pure reactive core) is deliberately left isolation-agnostic.
let uiIsolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

// The GTK4/Qt toolkits install a custom main-actor executor (so Swift Concurrency runs on the toolkit
// loop). Enable the experimental custom-executors feature on those targets.
let customExecutors: [SwiftSetting] = [.enableExperimentalFeature("ExperimentalCustomExecutors")]

// Qt6 include/link flags, per platform. Qt ships as frameworks on macOS (Homebrew) and as plain
// include + lib directories on Linux/Windows. Set the QT_ROOT environment variable to your Qt prefix
// if it differs from these defaults (e.g. `QT_ROOT=/opt/qt6 swift build`).
let qtEnv = ProcessInfo.processInfo.environment["QT_ROOT"]
let qtCxxFlags: [String]
let qtLinkFlags: [String]
#if os(macOS)
let qtPrefix = qtEnv ?? "/opt/homebrew/opt/qt"
qtCxxFlags = ["-F\(qtPrefix)/lib"]
qtLinkFlags = [
    "-F\(qtPrefix)/lib",
    "-framework", "QtWidgets", "-framework", "QtGui", "-framework", "QtCore",
    "-Xlinker", "-rpath", "-Xlinker", "\(qtPrefix)/lib",
]
#elseif os(Linux)
// Debian/Ubuntu multiarch is the default; override QT_ROOT for other distros / custom installs.
let qtInc = qtEnv.map { "\($0)/include" } ?? "/usr/include/x86_64-linux-gnu/qt6"
let qtLib = qtEnv.map { "\($0)/lib" } ?? "/usr/lib/x86_64-linux-gnu"
qtCxxFlags = ["-I\(qtInc)", "-I\(qtInc)/QtCore", "-I\(qtInc)/QtGui", "-I\(qtInc)/QtWidgets"]
qtLinkFlags = ["-L\(qtLib)", "-Xlinker", "-rpath", "-Xlinker", qtLib, "-lQt6Widgets", "-lQt6Gui", "-lQt6Core"]
#elseif os(Windows)
// Best-effort default for the official Qt installer layout; override QT_ROOT to match your environment.
let qtBase = qtEnv ?? "C:/Qt/6/msvc2022_64"
qtCxxFlags = ["-I\(qtBase)/include", "-I\(qtBase)/include/QtCore", "-I\(qtBase)/include/QtGui", "-I\(qtBase)/include/QtWidgets"]
qtLinkFlags = ["-L\(qtBase)/lib", "-lQt6Widgets", "-lQt6Gui", "-lQt6Core"]
#else
qtCxxFlags = []
qtLinkFlags = []
#endif

// Pre-combine the GTK targets' SwiftSettings into explicitly-typed lets. Concatenating several
// `[SwiftSetting]` lists inline inside the big `targets` array literal pushes Swift 6.2's manifest
// type-checker over its time budget ("unable to type-check this expression in reasonable time" on
// Linux); giving each chain a known result type up front keeps it fast.
let gtkLibSwiftSettings: [SwiftSetting] = uiIsolation + customExecutors
let gtkExecutorCheckSwiftSettings: [SwiftSetting] = customExecutors

// HopUI: a native-Swift, multi-toolkit, demand-driven SwiftUI implementation for the desktop.
// See ARCHITECTURE.md for the full blueprint. Toolkits: GTK4 (cross-platform), Qt6 (cross-platform),
// AppKit (macOS), plus a native-SwiftUI build of the demo (macOS) for side-by-side comparison.

// Which toolkit(s) to include in the package. CI sets `HOP_TOOLKIT` to build/test ONE toolkit in
// isolation on a runner that has only that toolkit installed — e.g. `HOP_TOOLKIT=qt` on a Qt-only box
// keeps the GTK targets (which need GTK) out of the build graph entirely, so `swift build`/`swift test`
// don't require GTK. Unset includes every toolkit (local dev and the macOS CI job).
let selectedToolkit = ProcessInfo.processInfo.environment["HOP_TOOLKIT"]?.lowercased()
func toolkitEnabled(_ name: String) -> Bool { selectedToolkit == nil || selectedToolkit == name }

// The reactive core + SwiftUI-mirroring API surface — zero toolkit dependencies, always included.
// (HopPackaging + the `hoppack` CLI used to live here too; they're now their own standalone package at
// Tools/HopPackaging, since they're toolkit-independent and have their own dependency set.)
var products: [Product] = [
    .library(name: "HopGraph", targets: ["HopGraph"]),
    .library(name: "HopPlatform", targets: ["HopPlatform"]),
    .library(name: "HopUI", targets: ["HopUI"]),
]
// Package-level dependency: apple/swift-log — the standard Swift logging facade, which HopPlatform's
// OS-native log sinks (os_log / journald / OutputDebugString) plug into as `LogHandler`s. swift-log has zero
// transitive dependencies, so the runtime core stays lean. Otherwise the core libraries + toolkit bindings
// depend only on system libraries (GTK via pkg-config, Qt/WinUI/journald via local shims / pkg-config).
// (The packaging tool's other external deps remain in Tools/HopPackaging.)
let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
]
// HopPlatform builds on swift-log (the logging facade) everywhere; its OS-native sinks plug in as handlers.
// The journald sink additionally needs libsystemd on Linux. macOS uses os_log and Windows OutputDebugStringW
// — both from toolchain-implicit modules (os / WinSDK) — so only Linux adds a C target.
var hopPlatformDeps: [Target.Dependency] = [.product(name: "Logging", package: "swift-log")]
#if os(Linux)
hopPlatformDeps.append(.target(name: "Csystemd"))
#endif

var targets: [Target] = [
    .target(name: "HopGraph"),
    .testTarget(name: "HopGraphTests", dependencies: ["HopGraph"]),
    // The OS-keyed, UI-free foundation layer (logging, the run-loop concurrency seam, …). No toolkit/UI
    // deps, no default MainActor isolation (like HopGraph) — usable from any layer. Its only conditional
    // dependency is Csystemd (journald) on Linux.
    .target(name: "HopPlatform", dependencies: hopPlatformDeps),
    .testTarget(name: "HopPlatformTests", dependencies: ["HopPlatform"]),
    .target(name: "HopUI", dependencies: ["HopGraph", "HopPlatform"], swiftSettings: uiIsolation),
    .testTarget(name: "HopUITests", dependencies: ["HopUI"]),
]

// journald sink for HopPlatform's logging (Linux only). Resolved via pkg-config libsystemd, like CGTK4's
// gtk4 — the systemLibrary just surfaces <systemd/sd-journal.h>; the sd_journal_sendv call is in Swift.
#if os(Linux)
targets += [
    .systemLibrary(name: "Csystemd", path: "Sources/Csystemd", pkgConfig: "libsystemd",
                   providers: [.apt(["libsystemd-dev"])]),
]
#endif

if toolkitEnabled("gtk") {
    products += [
        .library(name: "HopGTK4", targets: ["HopGTK4"]),
        // Headless check that the GTK4 custom run-loop executor routes Swift Concurrency onto GLib's loop.
        .executable(name: "hop-executor-check", targets: ["HopExecutorCheck"]),
    ]
    targets += [
        // GTK4 C ABI. Resolved via pkg-config on macOS (brew) and Linux (apt); on Windows pkgConfig is
        // nil and CGTK4's include/link flags are supplied explicitly (see the gtk* derivation above).
        .systemLibrary(
            name: "CGTK4",
            path: "Sources/CGTK4",
            pkgConfig: "gtk4",
            providers: [.brew(["gtk4"]), .apt(["libgtk-4-dev"])]
        ),
        .target(name: "HopGTK4", dependencies: ["HopUI", "CGTK4"],
                swiftSettings: gtkLibSwiftSettings),
        // Offscreen Cairo pixel-rendering tests for the GTK4 shape path (headless; no display).
        .testTarget(name: "HopGTK4Tests", dependencies: ["HopGTK4", "CGTK4"]),
        .executableTarget(name: "HopExecutorCheck", dependencies: ["HopUI", "HopGTK4", "CGTK4"], swiftSettings: gtkExecutorCheckSwiftSettings),
    ]
}

if toolkitEnabled("qt") {
    products += [
        .library(name: "HopQt", targets: ["HopQt"]),
    ]
    targets += [
        // Qt6 toolkit. Qt has no C ABI, so CQt is a C++ target exposing a pure-C header; the include/link
        // flags above adapt to macOS frameworks vs Linux/Windows include+lib dirs (override via QT_ROOT).
        .target(
            name: "CQt",
            cxxSettings: [.unsafeFlags(qtCxxFlags)],
            linkerSettings: [.unsafeFlags(qtLinkFlags)]
        ),
        .target(name: "HopQt", dependencies: ["HopUI", "CQt"], swiftSettings: uiIsolation + customExecutors),
        // Offscreen QImage pixel-rendering tests for the Qt shape path (headless; no display/QApplication).
        .testTarget(name: "HopQtTests", dependencies: ["HopQt", "CQt"]),
    ]
}

if toolkitEnabled("appkit") {
    products += [
        .library(name: "HopAppKit", targets: ["HopAppKit"]),
    ]
    targets += [
        // The AppKit toolkit (macOS only; file contents are guarded by #if canImport(AppKit)).
        .target(name: "HopAppKit", dependencies: ["HopUI"], swiftSettings: uiIsolation),
        .testTarget(name: "HopAppKitTests", dependencies: ["HopAppKit"]),
    ]
}

// WinUI 3 (Windows App SDK) toolkit — Windows-only, gated behind `#if os(Windows)` like AppKit is behind
// `canImport(AppKit)`. WinUI/WinRT has no C ABI, so — exactly like CQt wraps Qt's C++ behind a pure-C
// surface — `CWinUI` is a hand-written C++/WinRT shim that HopWinUI calls; there is no heavyweight WinRT
// projection dependency. Run `scripts/setup-winui.ps1` once to stage the WinUI C++/WinRT headers + import
// libs + Windows App Runtime bootstrap into `.winui/`; it writes `.winui/cflags` and `.winui/libs` (one
// flag per line, read below). C++/WinRT requires C++20.
#if os(Windows)
if toolkitEnabled("winui") {
    let winuiDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".winui").path
    // Read a `.winui/<file>` flag list (one flag per line, so include/lib paths with spaces stay intact).
    // Split on `isNewline` — a Windows CRLF is a single Swift grapheme, so comparing to "\n"/"\r" misses it.
    func winuiFlags(_ file: String) -> [String] {
        guard let text = try? String(contentsOfFile: "\(winuiDir)/\(file)", encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }
    products += [
        .library(name: "HopWinUI", targets: ["HopWinUI"]),
    ]
    targets += [
        // The C++/WinRT shim exposing a pure-C surface over WinUI 3 (Microsoft.UI.Xaml). Include/link flags
        // and the cppwinrt-generated headers come from `.winui/` (produced by scripts/setup-winui.ps1);
        // flags use forward slashes (clang rejects backslash include paths).
        .target(name: "CWinUI",
                cxxSettings: [.unsafeFlags(winuiFlags("cflags"))],  // C++20 comes from cxxLanguageStandard below
                linkerSettings: [.unsafeFlags(winuiFlags("libs"))]),
        .target(name: "HopWinUI", dependencies: ["HopUI", "CWinUI"], swiftSettings: uiIsolation + customExecutors),
    ]
}
#endif

let package = Package(
    name: "hop",
    platforms: [.macOS(.v15)],  // macOS 15: TaskExecutor / withTaskExecutorPreference (custom run-loop executor)
    products: products,
    dependencies: packageDependencies,
    targets: targets,
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx20  // C++/WinRT (CWinUI shim) needs C++20's <coroutine>; CQt's C++ is forward-compatible
)

// The demo apps (every toolkit, plus the native-SwiftUI reference) live in their own package now —
// Demos/Showcase — which depends on this package and on the standalone HopUIComboBox component
// package. See that package and scripts/run_demo.sh.
