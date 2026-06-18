// swift-tools-version: 6.2
import PackageDescription

// HopPackaging + the `hoppack` CLI: the native-app packaging tool for HopUI apps. Split out of the root
// `hop` package into its own standalone package so it builds and tests independently of the UI toolkits
// (it has no GTK/Qt/AppKit/WinUI dependency — it orchestrates builds and produces dmg/flatpak/msix
// distributions). Its dependencies (process/path/YAML/arg-parsing) are cross-platform, so this package
// builds on every host.
//
// `hoppack` uses its current working directory as the package directory to operate on, so the location of
// the built `hoppack` binary is irrelevant: CI builds it here and runs it from the app package's directory
// (see scripts/ci/package.sh / package.ps1).

let package = Package(
    name: "HopPackaging",
    platforms: [.macOS(.v15)],  // matches the root package; swift-subprocess's async APIs target recent SDKs
    products: [
        .library(name: "HopPackaging", targets: ["HopPackaging"]),
        .executable(name: "hoppack", targets: ["hoppack"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-system", from: "1.4.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", .upToNextMinor(from: "0.5.0")),
    ],
    targets: [
        // The packaging engine: an async pipeline of Stages, per-platform backends, and an hoppack.yaml model.
        .target(name: "HopPackaging", dependencies: [
            .product(name: "Yams", package: "Yams"),
            .product(name: "SystemPackage", package: "swift-system"),
            .product(name: "Subprocess", package: "swift-subprocess"),
        ]),
        .testTarget(name: "HopPackagingTests", dependencies: ["HopPackaging"]),
        // The `hoppack` command-line tool: assemble / run / package subcommands over HopPackaging.
        .executableTarget(name: "hoppack", dependencies: [
            "HopPackaging",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
