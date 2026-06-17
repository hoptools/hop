// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The built-in stages. The example pipeline from the spec — ProcessResources → BuildApp → PackageApp —
// is realized here, with an explicit AssembleApp step between build and package (the unit the `assemble`
// command produces) and a LaunchApp step for `run`. Resource/assemble/launch/package work is delegated to
// the target's `PlatformBackend`; only `BuildAppStage` is platform-independent (it shells out to SwiftPM).

/// Stage 1: process and stage the app's resources (icons + declared resource files). Delegates to the
/// backend, which knows the platform's resource layout.
public struct ProcessResourcesStage: Stage {
    public let backend: any PlatformBackend
    public init(_ backend: any PlatformBackend) { self.backend = backend }
    public var name: String { "ProcessResources" }
    public func run(_ context: PackagingContext) async throws -> PackagingContext {
        try await backend.processResources(context)
    }
}

/// Stage 2: build the SwiftPM executable for the target toolkit and record the binary's path. Platform-
/// independent: it runs `swift build` with `HOP_TOOLKIT` set so the package's toolkit gating selects the
/// right targets, then asks SwiftPM for the bin path.
public struct BuildAppStage: Stage {
    public init() {}
    public var name: String { "BuildApp" }

    public func run(_ context: PackagingContext) async throws -> PackagingContext {
        var context = context
        let exe = context.metadata.executable
        let env = ["HOP_TOOLKIT": context.target.toolkit.hopToolkitEnvironmentValue]
        let config = context.configuration.swiftBuildValue

        try await context.runner.run(
            "swift", ["build", "-c", config, "--product", exe],
            workingDirectory: context.packageDirectory, environment: env)

        let binPath = try await context.runner.capture(
            "swift", ["build", "-c", config, "--show-bin-path"],
            workingDirectory: context.packageDirectory, environment: env)

        var binary = FilePath(binPath).appending(exe)
        if context.target.os == .windows { binary = FilePath(binPath).appending("\(exe).exe") }
        context.builtExecutable = binary
        context.logger.detail("Built \(binary.string)")
        return context
    }
}

/// Stage 3: assemble the platform application (`.app` / app dir / app folder) from the built executable,
/// processed resources, and metadata. Delegates to the backend; the result is the `assemble` command's output.
public struct AssembleAppStage: Stage {
    public let backend: any PlatformBackend
    public init(_ backend: any PlatformBackend) { self.backend = backend }
    public var name: String { "AssembleApp" }
    public func run(_ context: PackagingContext) async throws -> PackagingContext {
        try await backend.assembleApp(context)
    }
}

/// Stage 4a: package the assembled app into the platform distribution (dmg / flatpak / msix).
public struct PackageAppStage: Stage {
    public let backend: any PlatformBackend
    public init(_ backend: any PlatformBackend) { self.backend = backend }
    public var name: String { "PackageApp (\(backend.distributionFormat))" }
    public func run(_ context: PackagingContext) async throws -> PackagingContext {
        try await backend.packageApp(context)
    }
}

/// Stage 4b: launch the assembled app the idiomatic way for the platform (`run` command).
public struct LaunchAppStage: Stage {
    public let backend: any PlatformBackend
    public init(_ backend: any PlatformBackend) { self.backend = backend }
    public var name: String { "LaunchApp" }
    public func run(_ context: PackagingContext) async throws -> PackagingContext {
        try await backend.launch(context)
        return context
    }
}
