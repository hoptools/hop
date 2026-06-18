// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Yams

// The decoded hoppack.yaml. The file is a mapping whose reserved `metadata:` key holds common metadata
// and whose remaining keys are platform sections (e.g. `macos-aarch64-appkit`). Resolving for a target
// layers that section over the common block (see `Metadata.merged(over:)`).
//
//   metadata:
//     identifier: net.hoptools.hopdemo
//     version: 1.0.0
//   macos-aarch64-appkit:
//     title: HopUI Demo (AppKit)
//     executable: hop-demo-appkit
//   linux-x86_64-gtk4:
//     title: HopUI Demo (GTK4)
//     executable: hop-demo-gtk4

/// The parsed hoppack.yaml: a common metadata block plus per-platform overrides.
public struct HoppackConfig: Sendable {
    /// The top-level `metadata:` block — common keys inherited by every platform section.
    public var common: Metadata
    /// Platform sections keyed by their triple.
    public var platforms: [PlatformTriple: Metadata]

    public init(common: Metadata = Metadata(), platforms: [PlatformTriple: Metadata] = [:]) {
        self.common = common
        self.platforms = platforms
    }

    /// The default config file name, expected alongside Package.swift.
    public static let defaultFileName = "hoppack.yaml"

    /// Load and parse an hoppack.yaml from disk.
    public static func load(from path: FilePath) throws -> HoppackConfig {
        guard let text = try? String(contentsOfFile: path.string, encoding: .utf8) else {
            throw PackagingError.configNotFound(path: path.string)
        }
        do {
            return try parse(yaml: text)
        } catch let error as PackagingError {
            throw error
        } catch {
            throw PackagingError.configInvalid(reason: "\(error)")
        }
    }

    /// Parse hoppack.yaml content.
    public static func parse(yaml: String) throws -> HoppackConfig {
        return try YAMLDecoder().decode(HoppackConfig.self, from: yaml)
    }

    /// Resolve the merged, defaulted metadata for a target: the platform section layered over the common
    /// block, with required-field defaults applied.
    public func resolved(for triple: PlatformTriple, packageName: String) throws -> ResolvedMetadata {
        let section = platforms[triple] ?? Metadata()
        let merged = section.merged(over: common)
        return try ResolvedMetadata(merged, triple: triple, packageName: packageName)
    }

    /// Platform sections declared in the file, sorted by key — for diagnostics and target auto-selection.
    public var declaredTriples: [PlatformTriple] {
        platforms.keys.sorted { $0.key < $1.key }
    }
}

extension HoppackConfig: Decodable {
    /// A coding key that accepts any string, so we can enumerate the file's top-level keys and treat each
    /// recognized platform triple as a section (and the reserved `metadata` key as the common block).
    private struct AnyKey: CodingKey {
        var stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var common = Metadata()
        var platforms: [PlatformTriple: Metadata] = [:]
        for key in container.allKeys {
            if key.stringValue == "metadata" {
                common = try container.decode(Metadata.self, forKey: key)
            } else if let triple = PlatformTriple(key.stringValue) {
                platforms[triple] = try container.decode(Metadata.self, forKey: key)
            }
            // Unrecognized top-level keys are ignored (forward-compatible: e.g. a future schema marker).
        }
        self.init(common: common, platforms: platforms)
    }
}
