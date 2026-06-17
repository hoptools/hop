// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import ArgumentParser
import HopPackaging
import SystemPackage

// `hoppack` — the command-line driver for HopPackaging. It exposes three subcommands over an async
// pipeline of packaging Stages: `assemble` (build a native app), `run` (assemble + launch), and `package`
// (assemble + produce a dmg/flatpak/msix). All are driven by an hoppack.yaml next to Package.swift.

@main
struct Hoppack: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hoppack",
        abstract: "Lint, process resources, and package a Swift app into native platform distributions.",
        discussion: """
            Driven by an hoppack.yaml at the package root. Each platform section (e.g. macos-aarch64-appkit,
            linux-x86_64-gtk4, windows-x86_64-winui) supplies metadata (title, executable, launchargs, …),
            falling back to the common top-level 'metadata' block.
            """,
        version: "0.1.0",
        subcommands: [Assemble.self, Run.self, Package.self],
        defaultSubcommand: Assemble.self)
}

/// Options shared by every subcommand.
struct GlobalOptions: ParsableArguments {
    @Option(name: [.customShort("C"), .customLong("package-path")],
            help: "Path to the Swift package directory (containing Package.swift).")
    var packagePath: String = "."

    @Option(name: .long, help: "Path to hoppack.yaml (default: <package-path>/hoppack.yaml).")
    var config: String?

    @Option(name: [.customShort("t"), .long],
            help: "Target as 'os-arch-toolkit' (e.g. macos-aarch64-appkit) or a toolkit name (appkit, swiftui, gtk4, qt, winui). Defaults to the matching section for this host.")
    var target: String?

    @Option(name: [.customShort("c"), .long], help: "Build configuration: debug or release.")
    var configuration: BuildConfigurationArgument = .release

    @Flag(name: [.short, .long], help: "Echo the commands being run.")
    var verbose: Bool = false

    /// Build the packager for these options.
    func makePackager() throws -> HopPackager {
        try HopPackager(
            packageDirectory: FilePath(packagePath),
            configPath: config.map(FilePath.init(_:)),
            targetSpecifier: target,
            configuration: configuration.value,
            verbose: verbose)
    }
}

/// `BuildConfiguration` as a parsable argument (kept separate so HopPackaging needn't depend on ArgumentParser).
enum BuildConfigurationArgument: String, ExpressibleByArgument, CaseIterable {
    case debug, release
    var value: BuildConfiguration { self == .debug ? .debug : .release }
}

struct Assemble: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Assemble the package into a native app for the target platform.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let result = try await options.makePackager().assemble()
        if let app = result.appArtifact { print("✓ Assembled \(app.string)") }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Assemble the app and launch it the idiomatic way for the platform.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        _ = try await options.makePackager().run()
    }
}

struct Package: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Assemble the app and bundle it into the platform distribution (dmg / flatpak / msix).")
    @OptionGroup var options: GlobalOptions

    @Option(name: [.customShort("o"), .long], help: "Write the distribution to this path (e.g. dist/macos-aarch64-appkit.dmg).")
    var output: String?

    func run() async throws {
        let result = try await options.makePackager().package(outputPath: output.map(FilePath.init(_:)))
        if let bundle = result.packageArtifact { print("✓ Packaged \(bundle.string)") }
    }
}
