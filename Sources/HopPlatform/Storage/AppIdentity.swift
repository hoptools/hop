// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Identifies an application for on-disk scoping (storage dirs, the settings file). The `identifier` —
// reverse-DNS like "dev.hop.demo", the same id `hoppack` uses for the bundle/package — becomes the
// per-app subdirectory; `name` is for display only.

/// A stable identity for the running app, used to namespace its storage.
public struct AppIdentity: Sendable, Equatable {
    /// Reverse-DNS identifier, used as the on-disk subdirectory name (e.g. "dev.hop.demo").
    public var identifier: String
    /// Human-readable application name (display only; not used in paths).
    public var name: String

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}
