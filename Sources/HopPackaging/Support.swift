// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

// Cross-cutting support: errors, logging, and the small filesystem helpers the backends share.

/// Errors surfaced by the packaging engine. Conforms to `LocalizedError` so the CLI prints a clean message.
public enum PackagingError: Error, CustomStringConvertible, Sendable {
    case configNotFound(path: String)
    case configInvalid(reason: String)
    case missingMetadata(key: String, target: PlatformTriple)
    case noMatchingTarget(host: String, available: [String])
    case ambiguousTarget(host: String, candidates: [String])
    case unknownTarget(spec: String)
    case unsupportedToolkit(toolkit: Toolkit, os: OS)
    case commandFailed(command: String, status: String, stderr: String?)
    case missingArtifact(stage: String, what: String)
    case toolUnavailable(tool: String, hint: String)

    public var description: String {
        switch self {
        case .configNotFound(let path):
            return "No hoppack.yaml found at \(path)"
        case .configInvalid(let reason):
            return "Invalid hoppack.yaml: \(reason)"
        case .missingMetadata(let key, let target):
            return "hoppack.yaml is missing required metadata key '\(key)' for target \(target.key) (set it in the platform section or the common 'metadata' block)"
        case .noMatchingTarget(let host, let available):
            return "No hoppack.yaml section matches this host (\(host)). Available targets: \(available.isEmpty ? "(none)" : available.joined(separator: ", "))"
        case .ambiguousTarget(let host, let candidates):
            return "Multiple hoppack.yaml sections match this host (\(host)): \(candidates.joined(separator: ", ")). Disambiguate with --target."
        case .unknownTarget(let spec):
            return "Unrecognized --target '\(spec)'. Use an os-arch-toolkit triple (e.g. macos-aarch64-appkit) or a toolkit name (appkit, swiftui, gtk4, qt, winui)."
        case .unsupportedToolkit(let toolkit, let os):
            return "Toolkit \(toolkit.rawValue) is not supported on \(os.rawValue)."
        case .commandFailed(let command, let status, let stderr):
            let tail = (stderr?.isEmpty == false) ? "\n\(stderr!)" : ""
            return "Command failed (\(status)): \(command)\(tail)"
        case .missingArtifact(let stage, let what):
            return "Stage '\(stage)' requires \(what), but it has not been produced yet."
        case .toolUnavailable(let tool, let hint):
            return "Required tool '\(tool)' is not available. \(hint)"
        }
    }
}

extension PackagingError: LocalizedError {
    public var errorDescription: String? { description }
}

/// A minimal, `Sendable` console logger with a verbose tier. The packaging pipeline is sequential, so
/// plain `print` is sufficient (no interleaving concerns).
public struct Logger: Sendable {
    public var verbose: Bool
    public init(verbose: Bool = false) { self.verbose = verbose }

    /// Announce a pipeline stage.
    public func stage(_ message: String) { print("▶ \(message)") }
    /// A normal informational line.
    public func info(_ message: String) { print(message) }
    /// A success line.
    public func success(_ message: String) { print("✓ \(message)") }
    /// A warning.
    public func warn(_ message: String) { FileHandle.standardError.write(Data("⚠ \(message)\n".utf8)) }
    /// Verbose-only detail (e.g. the exact command being run).
    public func detail(_ message: String) { if verbose { print("  \(message)") } }
}

/// Shared filesystem helpers over `FilePath`, implemented with `FileManager` for portability.
public enum FileOps {
    private static var fm: FileManager { .default }

    public static func exists(_ path: FilePath) -> Bool {
        fm.fileExists(atPath: path.string)
    }

    public static func isDirectory(_ path: FilePath) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path.string, isDirectory: &isDir) && isDir.boolValue
    }

    /// Create a directory (and intermediates) if it does not already exist.
    public static func ensureDirectory(_ path: FilePath) throws {
        try fm.createDirectory(atPath: path.string, withIntermediateDirectories: true)
    }

    /// Remove `path` if present, then recreate it as an empty directory — used to stage a fresh app bundle.
    public static func recreateDirectory(_ path: FilePath) throws {
        if exists(path) { try fm.removeItem(atPath: path.string) }
        try fm.createDirectory(atPath: path.string, withIntermediateDirectories: true)
    }

    public static func remove(_ path: FilePath) throws {
        if exists(path) { try fm.removeItem(atPath: path.string) }
    }

    /// Copy a file or directory, replacing any existing item at the destination.
    public static func copy(_ source: FilePath, to destination: FilePath) throws {
        if exists(destination) { try fm.removeItem(atPath: destination.string) }
        if let parent = destination.removingLastComponent().string.nonEmpty {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        try fm.copyItem(atPath: source.string, toPath: destination.string)
    }

    /// Write text to a file, creating intermediate directories.
    public static func write(_ text: String, to path: FilePath) throws {
        if let parent = path.removingLastComponent().string.nonEmpty {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        try text.write(toFile: path.string, atomically: true, encoding: .utf8)
    }

    /// Mark a file executable (0o755).
    public static func makeExecutable(_ path: FilePath) throws {
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: path.string)
    }

    /// The immediate child names of a directory.
    public static func contents(of directory: FilePath) throws -> [String] {
        try fm.contentsOfDirectory(atPath: directory.string)
    }

    /// Copy every immediate child of `directory` into `destination`.
    public static func copyDirectoryContents(of directory: FilePath, into destination: FilePath) throws {
        try ensureDirectory(destination)
        for entry in (try? contents(of: directory)) ?? [] {
            try copy(directory.appending(entry), to: destination.appending(entry))
        }
    }

    /// Copy each declared resource path (relative to `base`) into `directory`, skipping any that are absent.
    public static func stageResources(_ relativePaths: [String], from base: FilePath, into directory: FilePath) throws {
        for relative in relativePaths {
            let source = base.appending(relative)
            guard exists(source) else { continue }
            let destination = directory.appending(source.lastComponent?.string ?? relative)
            try copy(source, to: destination)
        }
    }
}

private extension String {
    /// nil when empty — used to skip creating a directory for a path with no parent component.
    var nonEmpty: String? { isEmpty ? nil : self }
}
