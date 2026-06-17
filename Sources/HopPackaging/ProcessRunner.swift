// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Subprocess

// A thin wrapper over swift-subprocess so the rest of HopPackaging never touches the Subprocess API
// directly (one place to adapt if the pre-1.0 API shifts). Two modes: `run` streams the child's output to
// our terminal (for long tools like `swift build`); `capture` collects stdout as a string (for queries
// like `swift build --show-bin-path`). Both throw `PackagingError.commandFailed` on a nonzero exit.

public struct ProcessRunner: Sendable {
    public let logger: Logger
    public init(logger: Logger) { self.logger = logger }

    /// Run a tool, forwarding its stdout/stderr to this process's terminal. Throws on a nonzero exit.
    public func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: FilePath? = nil,
        environment overrides: [String: String] = [:]
    ) async throws {
        logger.detail("$ \(commandLine(executable, arguments, overrides))")
        // Forward the child's stdout/stderr straight to our terminal so the user sees live build progress.
        let result = try await Subprocess.run(
            .name(executable),
            arguments: Arguments(arguments),
            environment: environment(overrides),
            workingDirectory: workingDirectory,
            output: FileDescriptorOutput.currentStandardOutput,
            error: FileDescriptorOutput.currentStandardError
        )
        try check(result.terminationStatus, executable: executable, stderr: nil)
    }

    /// Run a tool and return its captured standard output (trimmed). Throws on a nonzero exit, embedding
    /// the captured standard error in the thrown `PackagingError`.
    @discardableResult
    public func capture(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: FilePath? = nil,
        environment overrides: [String: String] = [:]
    ) async throws -> String {
        logger.detail("$ \(commandLine(executable, arguments, overrides))")
        let result = try await Subprocess.run(
            .name(executable),
            arguments: Arguments(arguments),
            environment: environment(overrides),
            workingDirectory: workingDirectory,
            output: .string(limit: 64 * 1024 * 1024),
            error: .string(limit: 16 * 1024 * 1024)
        )
        try check(result.terminationStatus, executable: executable, stderr: result.standardError ?? nil)
        return (result.standardOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func environment(_ overrides: [String: String]) -> Environment {
        guard !overrides.isEmpty else { return .inherit }
        let pairs: [(Environment.Key, String?)] = overrides.map {
            (Environment.Key(stringLiteral: $0.key), Optional($0.value))
        }
        return .inherit.updating(Dictionary(uniqueKeysWithValues: pairs))
    }

    private func check(_ status: TerminationStatus, executable: String, stderr: String?) throws {
        guard status.isSuccess else {
            throw PackagingError.commandFailed(
                command: executable,
                status: "\(status)",
                stderr: stderr?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func commandLine(_ executable: String, _ arguments: [String], _ overrides: [String: String]) -> String {
        let env = overrides.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let cmd = ([executable] + arguments).joined(separator: " ")
        return env.isEmpty ? cmd : "\(env) \(cmd)"
    }
}
