// swift-tools-version: 6.3
import PackageDescription
import Foundation

// Every Swift UI target runs on the main actor, so default-isolate them to `MainActor`. This lets
// the code adopt Swift 6 strict concurrency cleanly without scattering @MainActor annotations.
// HopGraph (the pure reactive core) is deliberately left isolation-agnostic.
let uiIsolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

// The GTK4/Qt backends install a custom main-actor executor (so Swift Concurrency runs on the toolkit
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

// HopUI: a native-Swift, multi-backend, demand-driven SwiftUI implementation for the desktop.
// See ARCHITECTURE.md for the full blueprint. Backends: GTK4 (cross-platform), Qt6 (cross-platform),
// AppKit (macOS), plus a native-SwiftUI build of the demo (macOS) for side-by-side comparison.

// Which backend(s) to include in the package. CI sets `HOP_BACKEND` to build/test ONE backend in
// isolation on a runner that has only that toolkit installed — e.g. `HOP_BACKEND=qt` on a Qt-only box
// keeps the GTK targets (which need GTK) out of the build graph entirely, so `swift build`/`swift test`
// don't require GTK. Unset includes every backend (local dev and the macOS CI job).
let selectedBackend = ProcessInfo.processInfo.environment["HOP_BACKEND"]?.lowercased()
func backendEnabled(_ name: String) -> Bool { selectedBackend == nil || selectedBackend == name }

// The reactive core + SwiftUI-mirroring API surface — zero toolkit dependencies, always included.
var products: [Product] = [
    .library(name: "HopGraph", targets: ["HopGraph"]),
    .library(name: "HopUI", targets: ["HopUI"]),
]
var targets: [Target] = [
    .target(name: "HopGraph"),
    .testTarget(name: "HopGraphTests", dependencies: ["HopGraph"]),
    .target(name: "HopUI", dependencies: ["HopGraph"], swiftSettings: uiIsolation),
    .testTarget(name: "HopUITests", dependencies: ["HopUI"]),
]

if backendEnabled("gtk") {
    products += [
        .library(name: "HopGTK4", targets: ["HopGTK4"]),
        .executable(name: "hop-demo-gtk4", targets: ["HopDemoGTK4"]),
        // Headless check that the GTK4 custom run-loop executor routes Swift Concurrency onto GLib's loop.
        .executable(name: "hop-executor-check", targets: ["HopExecutorCheck"]),
    ]
    targets += [
        // GTK4 C ABI, resolved via pkg-config on every OS (macOS brew, Linux apt, Windows MSYS2).
        .systemLibrary(
            name: "CGTK4",
            path: "Sources/CGTK4",
            pkgConfig: "gtk4",
            providers: [.brew(["gtk4"]), .apt(["libgtk-4-dev"])]
        ),
        .target(name: "HopGTK4", dependencies: ["HopUI", "CGTK4"], swiftSettings: uiIsolation + customExecutors),
        // Offscreen Cairo pixel-rendering tests for the GTK4 shape path (headless; no display).
        .testTarget(name: "HopGTK4Tests", dependencies: ["HopGTK4", "CGTK4"]),
        .executableTarget(name: "HopDemoGTK4", dependencies: ["HopGTK4"], path: "Demo/HopDemoGTK4",
                          resources: [.copy("hop-logo.png")],
                          swiftSettings: uiIsolation + [.define("HOPUI_BACKEND_GTK4")] + noPrespecialize),
        .executableTarget(name: "HopExecutorCheck", dependencies: ["HopUI", "HopGTK4", "CGTK4"], swiftSettings: customExecutors),
    ]
}

if backendEnabled("qt") {
    products += [
        .library(name: "HopQt", targets: ["HopQt"]),
        .executable(name: "hop-demo-qt", targets: ["HopDemoQt"]),
    ]
    targets += [
        // Qt6 backend. Qt has no C ABI, so CQt is a C++ target exposing a pure-C header; the include/link
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
                          swiftSettings: uiIsolation + [.define("HOPUI_BACKEND_QT")] + noPrespecialize),
    ]
}

if backendEnabled("appkit") {
    products += [
        .library(name: "HopAppKit", targets: ["HopAppKit"]),
        .executable(name: "hop-demo-appkit", targets: ["HopDemoAppKit"]),
    ]
    targets += [
        // The AppKit backend (macOS only; file contents are guarded by #if canImport(AppKit)).
        .target(name: "HopAppKit", dependencies: ["HopUI"], swiftSettings: uiIsolation),
        .testTarget(name: "HopAppKitTests", dependencies: ["HopAppKit"]),
        // Each demo executable compiles its OWN copy of the shared Demo/ContentView.swift +
        // Demo/HopDemoApp.swift (symlinked into the target's folder under Demo/) with exactly one
        // HOPUI_BACKEND_* define, so shared app code can interpose toolkit-specific code via #if.
        .executableTarget(name: "HopDemoAppKit", dependencies: ["HopAppKit"], path: "Demo/HopDemoAppKit",
                          resources: [.copy("hop-logo.png")],
                          swiftSettings: uiIsolation + [.define("HOPUI_BACKEND_APPKIT")] + noPrespecialize),
    ]
}

let package = Package(
    name: "hop",
    platforms: [.macOS(.v15)],  // macOS 15: TaskExecutor / withTaskExecutorPreference (custom run-loop executor)
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)

#if os(macOS)
// The native-SwiftUI build of the demo runs only on Apple platforms (SwiftUI is Apple-only). It
// compiles the SAME shared ContentView with HOPUI_BACKEND_SWIFTUI, importing Apple's SwiftUI instead
// of HopUI — no shims, no HopUI dependency. Grouped with the AppKit (Apple) backend selection.
if backendEnabled("appkit") {
    package.products += [
        .executable(name: "hop-demo-native", targets: ["HopDemoNative"]),
    ]
    package.targets += [
        .executableTarget(name: "HopDemoNative", path: "Demo/HopDemoNative",
                          resources: [.copy("hop-logo.png")],
                          swiftSettings: [.define("HOPUI_BACKEND_SWIFTUI")] + noPrespecialize),
    ]
}
#endif
