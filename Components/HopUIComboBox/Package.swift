// swift-tools-version: 6.2
import PackageDescription
import Foundation

// HopUIComboBox — a standalone, third-party HopUI component package. It adds a `ComboBox` view backed by
// each toolkit's native combo box (NSComboBox / GtkComboBoxText / QComboBox / WinUI ComboBox) using ONLY
// HopUI's public extensibility seams (`HopRepresentable` + `WidgetComponent.makeNative`), with no edits to
// `hop`. It depends on the root `hop` package (for `HopUI`) at ../../ and is consumed by the Showcase app.

let uiIsolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

// Build only the selected toolkit's targets when HOP_TOOLKIT is set (mirrors the root package), so a
// single-toolkit CI runner doesn't need every toolkit's native libraries. Unset = all toolkits.
let selectedToolkit = ProcessInfo.processInfo.environment["HOP_TOOLKIT"]?.lowercased()
func toolkitEnabled(_ name: String) -> Bool { selectedToolkit == nil || selectedToolkit == name }

// Qt6 include/link flags (same derivation as the root package; override QT_ROOT for non-default installs).
let qtEnv = ProcessInfo.processInfo.environment["QT_ROOT"]
let qtCxxFlags: [String]
let qtLinkFlags: [String]
#if os(macOS)
let qtPrefix = qtEnv ?? "/opt/homebrew/opt/qt"
qtCxxFlags = ["-F\(qtPrefix)/lib"]
qtLinkFlags = ["-F\(qtPrefix)/lib", "-framework", "QtWidgets", "-framework", "QtGui", "-framework", "QtCore",
               "-Xlinker", "-rpath", "-Xlinker", "\(qtPrefix)/lib"]
#elseif os(Linux)
let qtInc = qtEnv.map { "\($0)/include" } ?? "/usr/include/x86_64-linux-gnu/qt6"
let qtLib = qtEnv.map { "\($0)/lib" } ?? "/usr/lib/x86_64-linux-gnu"
qtCxxFlags = ["-I\(qtInc)", "-I\(qtInc)/QtCore", "-I\(qtInc)/QtGui", "-I\(qtInc)/QtWidgets"]
qtLinkFlags = ["-L\(qtLib)", "-Xlinker", "-rpath", "-Xlinker", qtLib, "-lQt6Widgets", "-lQt6Gui", "-lQt6Core"]
#elseif os(Windows)
let qtBase = qtEnv ?? "C:/Qt/6/msvc2022_64"
qtCxxFlags = ["-I\(qtBase)/include", "-I\(qtBase)/include/QtCore", "-I\(qtBase)/include/QtGui", "-I\(qtBase)/include/QtWidgets"]
qtLinkFlags = ["-L\(qtBase)/lib", "-lQt6Widgets", "-lQt6Gui", "-lQt6Core"]
#else
qtCxxFlags = []
qtLinkFlags = []
#endif

var products: [Product] = [
    .library(name: "HopUIComboBox", targets: ["HopUIComboBox"]),
]
var targets: [Target] = [
    .target(name: "HopUIComboBox", dependencies: [.product(name: "HopUI", package: "hop")], swiftSettings: uiIsolation),
]

if toolkitEnabled("appkit") {
    products += [.library(name: "HopUIComboBoxAppKit", targets: ["HopUIComboBoxAppKit"])]
    targets += [
        .target(name: "HopUIComboBoxAppKit",
                dependencies: ["HopUIComboBox", .product(name: "HopUI", package: "hop")],
                swiftSettings: uiIsolation),
    ]
}

if toolkitEnabled("gtk") {
    products += [.library(name: "HopUIComboBoxGTK4", targets: ["HopUIComboBoxGTK4"])]
    targets += [
        .systemLibrary(name: "CComboBoxGTK", path: "Sources/CComboBoxGTK",
                       pkgConfig: "gtk4", providers: [.brew(["gtk4"]), .apt(["libgtk-4-dev"])]),
        .target(name: "HopUIComboBoxGTK4",
                dependencies: ["HopUIComboBox", "CComboBoxGTK", .product(name: "HopUI", package: "hop")],
                swiftSettings: uiIsolation),
    ]
}

if toolkitEnabled("qt") {
    products += [.library(name: "HopUIComboBoxQt", targets: ["HopUIComboBoxQt"])]
    targets += [
        .target(name: "CComboBoxQt",
                cxxSettings: [.unsafeFlags(qtCxxFlags)],
                linkerSettings: [.unsafeFlags(qtLinkFlags)]),
        .target(name: "HopUIComboBoxQt",
                dependencies: ["HopUIComboBox", "CComboBoxQt", .product(name: "HopUI", package: "hop")],
                swiftSettings: uiIsolation),
    ]
}

#if os(Windows)
if toolkitEnabled("winui") {
    products += [.library(name: "HopUIComboBoxWinUI", targets: ["HopUIComboBoxWinUI"])]
    // WinUI include/link flags come from the root package's `.winui/` staging (scripts/setup-winui.ps1).
    let winuiDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../.winui").path
    func winuiFlags(_ file: String) -> [String] {
        guard let text = try? String(contentsOfFile: "\(winuiDir)/\(file)", encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }
    targets += [
        .target(name: "CComboBoxWinUI",
                cxxSettings: [.unsafeFlags(winuiFlags("cflags"))],
                linkerSettings: [.unsafeFlags(winuiFlags("libs"))]),
        .target(name: "HopUIComboBoxWinUI",
                dependencies: ["HopUIComboBox", "CComboBoxWinUI", .product(name: "HopUI", package: "hop")],
                swiftSettings: uiIsolation),
    ]
}
#endif

let package = Package(
    name: "HopUIComboBox",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: [.package(path: "../../")],
    targets: targets,
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx20
)
