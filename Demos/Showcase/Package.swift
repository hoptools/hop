// swift-tools-version: 6.2
import PackageDescription
import Foundation

// The HopUI Showcase app — relocated out of the root `hop` package into its own package so it consumes
// HopUI exactly like a real downstream app would: via package dependencies. It depends on the root `hop`
// package (../../) for HopUI + the toolkit backends, and on the standalone HopUIComboBox component
// package (../Components/HopUIComboBox) — demonstrating third-party toolkit extensibility.
//
// One shared ContentView/HopDemoApp (in Shared/, symlinked into each target) compiles per toolkit with a
// single HOPUI_TOOLKIT_* define, so the same SwiftUI-mirroring source drives every backend (and Apple's
// real SwiftUI for the reference build). Executable PRODUCT names stay `hop-demo-*` so hoppack.yaml and the
// launch/CI scripts keep working.

let uiIsolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]
// Same prespecialization workaround the demos needed in the root package (a generic @Environment +
// range-generics interaction crashes canonical prespecialized metadata); disable it in the executables.
let noPrespecialize: [SwiftSetting] = [.unsafeFlags(["-Xfrontend", "-disable-generic-metadata-prespecialization"])]

let selectedToolkit = ProcessInfo.processInfo.environment["HOP_TOOLKIT"]?.lowercased()
func toolkitEnabled(_ name: String) -> Bool { selectedToolkit == nil || selectedToolkit == name }

func combo(_ name: String) -> Target.Dependency { .product(name: name, package: "HopUIComboBox") }
func hop(_ name: String) -> Target.Dependency { .product(name: name, package: "hop") }

var products: [Product] = []
var targets: [Target] = []

if toolkitEnabled("appkit") {
    products += [.executable(name: "hop-demo-appkit", targets: ["ShowcaseAppKit"])]
    targets += [.executableTarget(name: "ShowcaseAppKit",
                                  dependencies: [hop("HopUI"), hop("HopAppKit"), combo("HopUIComboBox"), combo("HopUIComboBoxAppKit")],
                                  resources: [.copy("hop-logo.png")],
                                  swiftSettings: uiIsolation + [.define("HOPUI_TOOLKIT_APPKIT")] + noPrespecialize)]
}

if toolkitEnabled("gtk") {
    products += [.executable(name: "hop-demo-gtk4", targets: ["ShowcaseGTK4"])]
    targets += [.executableTarget(name: "ShowcaseGTK4",
                                  dependencies: [hop("HopUI"), hop("HopGTK4"), combo("HopUIComboBox"), combo("HopUIComboBoxGTK4")],
                                  resources: [.copy("hop-logo.png")],
                                  swiftSettings: uiIsolation + [.define("HOPUI_TOOLKIT_GTK4")] + noPrespecialize)]
}

if toolkitEnabled("qt") {
    products += [.executable(name: "hop-demo-qt", targets: ["ShowcaseQt"])]
    targets += [.executableTarget(name: "ShowcaseQt",
                                  dependencies: [hop("HopUI"), hop("HopQt"), combo("HopUIComboBox"), combo("HopUIComboBoxQt")],
                                  resources: [.copy("hop-logo.png")],
                                  swiftSettings: uiIsolation + [.define("HOPUI_TOOLKIT_QT")] + noPrespecialize)]
}

// HopUIComboBox is referenced by name only when a toolkit target depends on it; declare the dependency once.
var dependencies: [Package.Dependency] = [.package(path: "../../"), .package(path: "../../Components/HopUIComboBox")]

let package = Package(
    name: "Showcase",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)

// The native-SwiftUI reference build (Apple's SwiftUI; macOS only) — the SAME ContentView with
// HOPUI_TOOLKIT_SWIFTUI. It has no HopUI dependency (and no ComboBox — the playground falls back to a
// Picker there via #if). Included for the AppKit selection and its own HOP_TOOLKIT=swiftui selection.
#if os(macOS)
if toolkitEnabled("appkit") || toolkitEnabled("swiftui") {
    package.products += [.executable(name: "hop-demo-native", targets: ["ShowcaseNative"])]
    package.targets += [.executableTarget(name: "ShowcaseNative",
                                          resources: [.copy("hop-logo.png")],
                                          swiftSettings: [.define("HOPUI_TOOLKIT_SWIFTUI")] + noPrespecialize)]
}
#endif

// WinUI (Windows only) — its own toolkit + the ComboBox WinUI backing.
#if os(Windows)
if toolkitEnabled("winui") {
    package.products += [.executable(name: "hop-demo-winui", targets: ["ShowcaseWinUI"])]
    package.targets += [.executableTarget(name: "ShowcaseWinUI",
                                          dependencies: [hop("HopUI"), hop("HopWinUI"), combo("HopUIComboBox"), combo("HopUIComboBoxWinUI")],
                                          resources: [.copy("hop-logo.png")],
                                          swiftSettings: uiIsolation + [.define("HOPUI_TOOLKIT_WINUI")] + noPrespecialize)]
}
#endif
