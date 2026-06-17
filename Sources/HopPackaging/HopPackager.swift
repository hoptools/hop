// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

// The public entry point: load the config, resolve a target, pick the backend, and run the pipeline for a
// command. `hoppack`'s subcommands are thin wrappers over `assemble()` / `run()` / `package()`. The
// pipelines are assembled here, so adding a stage (signing between assemble and package, a lint stage at
// the front, …) is a one-line change in one place.

public struct HopPackager: Sendable {
    /// The fully-prepared context (config resolved, target chosen, paths computed).
    public let context: PackagingContext
    /// The platform backend selected for the target OS.
    public let backend: any PlatformBackend

    /// Prepare a packager from CLI-style inputs.
    /// - Parameters:
    ///   - packageDirectory: the Swift package root (contains Package.swift).
    ///   - configPath: explicit hoppack.yaml path, or nil to use `<package>/hoppack.yaml`.
    ///   - targetSpecifier: an `os-arch-toolkit` triple, a bare toolkit name, or nil to auto-detect.
    ///   - configuration: debug or release.
    ///   - verbose: echo the commands being run.
    public init(
        packageDirectory rawPackageDirectory: FilePath,
        configPath: FilePath? = nil,
        targetSpecifier: String? = nil,
        configuration: BuildConfiguration = .release,
        verbose: Bool = false
    ) throws {
        // Resolve to an absolute path so every derived path — the work dir, the assembled app, the flatpak
        // manifest and its `sources` dir, windeployqt's `{exe}` — is cwd-independent. Backends invoke tools
        // with a working directory set, so cwd-relative paths would otherwise compound (…/.build/…/.build/…).
        let packageDirectory = FilePath(FileManager.default.currentDirectoryPath)
            .pushing(rawPackageDirectory).lexicallyNormalized()
        let logger = Logger(verbose: verbose)
        let configFile = configPath ?? packageDirectory.appending(HoppackConfig.defaultFileName)
        let config = try HoppackConfig.load(from: configFile)
        let target = try Self.resolveTarget(specifier: targetSpecifier, config: config)
        let packageName = packageDirectory.lastComponent?.string ?? "App"
        let metadata = try config.resolved(for: target, packageName: packageName)
        let workDirectory = packageDirectory.appending(".build/hoppack/\(target.key)")

        self.backend = BackendRegistry.backend(for: target.os)
        self.context = PackagingContext(
            packageDirectory: packageDirectory,
            workDirectory: workDirectory,
            target: target,
            configuration: configuration,
            metadata: metadata,
            logger: logger,
            runner: ProcessRunner(logger: logger))
    }

    /// The pipeline that turns the Swift package into a native app: ProcessResources → BuildApp → AssembleApp.
    public func assemble() async throws -> PackagingContext {
        try await Pipeline([
            ProcessResourcesStage(backend),
            BuildAppStage(),
            AssembleAppStage(backend),
        ]).run(context)
    }

    /// Assemble, then launch the app the idiomatic way for the platform.
    public func run() async throws -> PackagingContext {
        let assembled = try await assemble()
        return try await Pipeline([LaunchAppStage(backend)]).run(assembled)
    }

    /// Assemble, then bundle into the platform distribution (dmg / flatpak / msix). When `outputPath` is
    /// given, the distribution is copied there (a stable artifact name for CI), updating `packageArtifact`.
    public func package(outputPath: FilePath? = nil) async throws -> PackagingContext {
        let assembled = try await assemble()
        var result = try await Pipeline([PackageAppStage(backend)]).run(assembled)
        if let outputPath, let artifact = result.packageArtifact {
            try FileOps.ensureDirectory(outputPath.removingLastComponent())
            try FileOps.copy(artifact, to: outputPath)
            result.packageArtifact = outputPath
            result.logger.success("Output \(outputPath.string)")
        }
        return result
    }

    /// The default file extension for this target's distribution (dmg / flatpak / msix).
    public var distributionExtension: String { backend.distributionFormat }

    /// Pick the target triple from an explicit specifier, or auto-detect from the host + config.
    static func resolveTarget(specifier: String?, config: HoppackConfig) throws -> PlatformTriple {
        if let specifier {
            if let triple = PlatformTriple(specifier) { return triple }
            if let toolkit = Toolkit(rawValue: specifier) {
                return PlatformTriple(os: PlatformTriple.hostOS, arch: PlatformTriple.hostArch, toolkit: toolkit)
            }
            throw PackagingError.unknownTarget(spec: specifier)
        }
        // No specifier: choose the single declared section matching this host's OS + arch.
        let hostKey = "\(PlatformTriple.hostOS.rawValue)-\(PlatformTriple.hostArch.rawValue)"
        let matches = config.declaredTriples.filter { $0.os == PlatformTriple.hostOS && $0.arch == PlatformTriple.hostArch }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw PackagingError.noMatchingTarget(host: hostKey, available: config.declaredTriples.map(\.key))
        default: throw PackagingError.ambiguousTarget(host: hostKey, candidates: matches.map(\.key))
        }
    }
}
