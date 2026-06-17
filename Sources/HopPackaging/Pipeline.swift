// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The heart of HopPackaging: an asynchronous pipeline of Stages. Each Stage transforms a value-type
// `PackagingContext` (threaded through the pipeline), accumulating artifacts — built executable, assembled
// app, final distribution. New capabilities (code signing, notarization, linting) are added simply by
// writing a new Stage and inserting it into the relevant pipeline; nothing else has to change.

/// The state threaded through a packaging pipeline. A value type, so stages can't accidentally share
/// mutable state across an `await`; each stage returns an updated copy with any artifacts it produced.
public struct PackagingContext: Sendable {
    /// The Swift package being packaged (the directory containing Package.swift).
    public let packageDirectory: FilePath
    /// A scratch directory for this target's intermediate + output artifacts (under `.build/hoppack/<key>`).
    public let workDirectory: FilePath
    /// The target being assembled/packaged.
    public let target: PlatformTriple
    /// The build configuration (debug/release).
    public let configuration: BuildConfiguration
    /// The merged, defaulted application metadata for this target.
    public let metadata: ResolvedMetadata
    public let logger: Logger
    public let runner: ProcessRunner

    // Artifacts produced as the pipeline runs:

    /// The compiled executable (set by `BuildAppStage`).
    public var builtExecutable: FilePath?
    /// The staged resources directory (set by the ProcessResources stage).
    public var resourcesDirectory: FilePath?
    /// The assembled platform application — `.app` bundle, Linux app dir, or Windows app folder.
    public var appArtifact: FilePath?
    /// The final platform distribution — `.dmg`, `.flatpak`, or `.msix`.
    public var packageArtifact: FilePath?

    public init(
        packageDirectory: FilePath,
        workDirectory: FilePath,
        target: PlatformTriple,
        configuration: BuildConfiguration,
        metadata: ResolvedMetadata,
        logger: Logger,
        runner: ProcessRunner
    ) {
        self.packageDirectory = packageDirectory
        self.workDirectory = workDirectory
        self.target = target
        self.configuration = configuration
        self.metadata = metadata
        self.logger = logger
        self.runner = runner
    }

    /// The assembled app, or a thrown error naming the stage that needed it.
    public func requireAppArtifact(stage: String) throws -> FilePath {
        guard let appArtifact else { throw PackagingError.missingArtifact(stage: stage, what: "an assembled app") }
        return appArtifact
    }

    /// The built executable, or a thrown error naming the stage that needed it.
    public func requireBuiltExecutable(stage: String) throws -> FilePath {
        guard let builtExecutable else { throw PackagingError.missingArtifact(stage: stage, what: "a built executable") }
        return builtExecutable
    }
}

/// One step in a packaging pipeline. Implementations are `Sendable` and pure with respect to the context:
/// they take a context and return an updated one. Keep stages small and composable.
public protocol Stage: Sendable {
    /// A short human-readable name shown as the stage runs.
    var name: String { get }
    /// Perform the stage's work and return the (possibly updated) context.
    func run(_ context: PackagingContext) async throws -> PackagingContext
}

/// An ordered sequence of stages, run one after another with the context threaded through. The pipeline
/// is the unit a command (assemble/run/package) assembles and executes.
public struct Pipeline: Sendable {
    public let stages: [any Stage]
    public init(_ stages: [any Stage]) { self.stages = stages }

    /// Run every stage in order, returning the final accumulated context.
    @discardableResult
    public func run(_ context: PackagingContext) async throws -> PackagingContext {
        var current = context
        for stage in stages {
            current.logger.stage(stage.name)
            current = try await stage.run(current)
        }
        return current
    }
}
