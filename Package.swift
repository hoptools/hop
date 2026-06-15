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

// GTK4 on Windows needs two workarounds that don't apply to macOS/Linux:
//   1. SwiftPM's built-in pkg-config parser trips over MSYS2's harfbuzz<->freetype2 `.pc` dependency
//      cycle and silently drops GTK's `-I` include flags, so the CGTK4 module can't find <gtk/gtk.h>.
//   2. The MSVC toolchain's linker (lld-link) can't consume MSYS2's GNU-format `.dll.a` import libs.
// So on Windows we bypass `pkgConfig:`, feed clang the include flags ourselves, and link against
// MSVC-style `.lib` import libraries generated from the GTK DLLs. Run `scripts/setup-windows.ps1`
// once to populate `.winlibs/` (the generated import libs + the captured pkg-config flag files).
// macOS and Linux are untouched: there `pkgConfig: "gtk4"` resolves normally and these stay empty.
let gtkPkgConfig: String?
let gtkCSwiftSettings: [SwiftSetting]
let gtkLinkerSettings: [LinkerSetting]
#if os(Windows)
let winlibsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".winlibs").path
func winlibsFlags(_ file: String) -> [String] {
    guard let text = try? String(contentsOfFile: "\(winlibsDir)/\(file)", encoding: .utf8) else { return [] }
    return text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}
gtkPkgConfig = nil
gtkCSwiftSettings = [.unsafeFlags(winlibsFlags("gtk4.cflags").flatMap { ["-Xcc", $0] })]
gtkLinkerSettings = [.unsafeFlags(winlibsFlags("gtk4.libs") + ["-L\(winlibsDir)"])]
#else
gtkPkgConfig = "gtk4"
gtkCSwiftSettings = []
gtkLinkerSettings = []
#endif

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
            pkgConfig: gtkPkgConfig,
            providers: [.brew(["gtk4"]), .apt(["libgtk-4-dev"])]
        ),
        .target(name: "HopGTK4", dependencies: ["HopUI", "CGTK4"],
                swiftSettings: uiIsolation + customExecutors + gtkCSwiftSettings,
                linkerSettings: gtkLinkerSettings),
        // Offscreen Cairo pixel-rendering tests for the GTK4 shape path (headless; no display).
        .testTarget(name: "HopGTK4Tests", dependencies: ["HopGTK4", "CGTK4"], swiftSettings: gtkCSwiftSettings),
        .executableTarget(name: "HopDemoGTK4", dependencies: ["HopGTK4"], path: "Demo/HopDemoGTK4",
                          resources: [.copy("hop-logo.png")],
                          swiftSettings: uiIsolation + [.define("HOPUI_TOOLKIT_GTK4")] + noPrespecialize + gtkCSwiftSettings),
        .executableTarget(name: "HopExecutorCheck", dependencies: ["HopUI", "HopGTK4", "CGTK4"], swiftSettings: customExecutors + gtkCSwiftSettings),
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
// compiles the SAME shared ContentView with HOPUI_TOOLKIT_SWIFTUI, importing Apple's SwiftUI instead
// of HopUI — no shims, no HopUI dependency. Grouped with the AppKit (Apple) toolkit selection.
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
