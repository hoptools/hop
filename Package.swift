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

// Workaround for a Swift runtime crash instantiating canonical *prespecialized* generic metadata
// (null deref in a `ClosedRange.Index` metadata completion) when a demo's generic `@Environment`
// access coexists with the module's range generics (Slider/List). Disabling prespecialization in the
// demo executables avoids building the bad canonical metadata list; libraries are unaffected.
let noPrespecialize: [SwiftSetting] = [.unsafeFlags(["-Xfrontend", "-disable-generic-metadata-prespecialization"])]

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
let gtkDemoSwiftSettings: [SwiftSetting] = uiIsolation + [.define("HOPUI_TOOLKIT_GTK4")] + noPrespecialize
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
var products: [Product] = [
    .library(name: "HopGraph", targets: ["HopGraph"]),
    .library(name: "HopUI", targets: ["HopUI"]),
]
// Package-level dependencies are added conditionally: only the WinUI toolkit (Windows-only) pulls in
// the swift-winui WinRT/WinUI 3 projection package, so macOS/Linux builds never need to resolve it.
var packageDependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "HopGraph"),
    .testTarget(name: "HopGraphTests", dependencies: ["HopGraph"]),
    .target(name: "HopUI", dependencies: ["HopGraph"], swiftSettings: uiIsolation),
    .testTarget(name: "HopUITests", dependencies: ["HopUI"]),
]

if toolkitEnabled("gtk") {
    products += [
        .library(name: "HopGTK4", targets: ["HopGTK4"]),
        .executable(name: "hop-demo-gtk4", targets: ["HopDemoGTK4"]),
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
        .executableTarget(name: "HopDemoGTK4", dependencies: ["HopGTK4"], path: "Demo/HopDemoGTK4",
                          resources: [.copy("hop-logo.png")],
                          swiftSettings: gtkDemoSwiftSettings),
        .executableTarget(name: "HopExecutorCheck", dependencies: ["HopUI", "HopGTK4", "CGTK4"], swiftSettings: gtkExecutorCheckSwiftSettings),
    ]
}

if toolkitEnabled("qt") {
    products += [
        .library(name: "HopQt", targets: ["HopQt"]),
        .executable(name: "hop-demo-qt", targets: ["HopDemoQt"]),
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
        .executableTarget(name: "HopDemoQt", dependencies: ["HopQt"], path: "Demo/HopDemoQt",
                          resources: [.copy("hop-logo.png")],
                          swiftSettings: uiIsolation + [.define("HOPUI_TOOLKIT_QT")] + noPrespecialize),
    ]
}

if toolkitEnabled("appkit") {
    products += [
        .library(name: "HopAppKit", targets: ["HopAppKit"]),
        .executable(name: "hop-demo-appkit", targets: ["HopDemoAppKit"]),
    ]
    targets += [
        // The AppKit toolkit (macOS only; file contents are guarded by #if canImport(AppKit)).
        .target(name: "HopAppKit", dependencies: ["HopUI"], swiftSettings: uiIsolation),
        .testTarget(name: "HopAppKitTests", dependencies: ["HopAppKit"]),
        // Each demo executable compiles its OWN copy of the shared Demo/ContentView.swift +
        // Demo/HopDemoApp.swift (symlinked into the target's folder under Demo/) with exactly one
        // HOPUI_TOOLKIT_* define, so shared app code can interpose toolkit-specific code via #if.
        .executableTarget(name: "HopDemoAppKit", dependencies: ["HopAppKit"], path: "Demo/HopDemoAppKit",
                          resources: [.copy("hop-logo.png")],
                          swiftSettings: uiIsolation + [.define("HOPUI_TOOLKIT_APPKIT")] + noPrespecialize),
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
    let winuiDemoSwiftSettings: [SwiftSetting] = uiIsolation + [.define("HOPUI_TOOLKIT_WINUI")] + customExecutors + noPrespecialize
    products += [
        .library(name: "HopWinUI", targets: ["HopWinUI"]),
        .executable(name: "hop-demo-winui", targets: ["HopDemoWinUI"]),
    ]
    targets += [
        // The C++/WinRT shim exposing a pure-C surface over WinUI 3 (Microsoft.UI.Xaml). Include/link flags
        // and the cppwinrt-generated headers come from `.winui/` (produced by scripts/setup-winui.ps1);
        // flags use forward slashes (clang rejects backslash include paths).
        .target(name: "CWinUI",
                cxxSettings: [.unsafeFlags(winuiFlags("cflags"))],  // C++20 comes from cxxLanguageStandard below
                linkerSettings: [.unsafeFlags(winuiFlags("libs"))]),
        .target(name: "HopWinUI", dependencies: ["HopUI", "CWinUI"], swiftSettings: uiIsolation + customExecutors),
        .executableTarget(name: "HopDemoWinUI", dependencies: ["HopWinUI"], path: "Demo/HopDemoWinUI",
                          resources: [.copy("hop-logo.png")],
                          swiftSettings: winuiDemoSwiftSettings),
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

#if os(macOS)
// The native-SwiftUI build of the demo runs only on Apple platforms (SwiftUI is Apple-only). It
// compiles the SAME shared ContentView with HOPUI_TOOLKIT_SWIFTUI, importing Apple's SwiftUI instead
// of HopUI. Grouped with the AppKit (Apple) toolkit selection.
if toolkitEnabled("appkit") {
    package.products += [
        .executable(name: "hop-demo-native", targets: ["HopDemoNative"]),
    ]
    package.targets += [
        .executableTarget(name: "HopDemoNative", path: "Demo/HopDemoNative",
                          resources: [.copy("hop-logo.png")],
                          swiftSettings: [.define("HOPUI_TOOLKIT_SWIFTUI")] + noPrespecialize),
    ]
}
#endif
