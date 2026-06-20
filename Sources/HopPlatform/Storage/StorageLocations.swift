// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Per-OS storage directories, scoped to an AppIdentity. Each follows the platform convention:
//   Apple   — ~/Library/Application Support/<id> (data & config) and ~/Library/Caches/<id>, via
//             FileManager.url(for:) so a future sandboxed build is redirected into its container.
//   Linux   — XDG base dirs ($XDG_DATA_HOME / $XDG_CONFIG_HOME / $XDG_CACHE_HOME, with the spec fallbacks
//             ~/.local/share, ~/.config, ~/.cache).
//   Windows — %LOCALAPPDATA%\<id> (data), %APPDATA%\<id> (config, roaming), %LOCALAPPDATA%\<id>\Cache.
//
// The XDG/Windows resolution is factored into pure functions (`xdgPath`/`windowsPath`) so the
// (error-prone) convention logic is unit-tested on any host, even though only one branch is wired in per OS.
// (A future refinement: redirect to WinRT ApplicationData when the app is MSIX-packaged.)

import Foundation

public enum StorageError: Error, Sendable, Equatable {
    /// A required platform environment variable (e.g. LOCALAPPDATA) was unset.
    case missingEnvironment(String)
}

public enum StorageLocations {
    /// Per-app data directory (created unless `create: false`).
    public static func applicationSupport(for id: AppIdentity, create: Bool = true) throws -> URL {
        try resolve(.applicationSupport, id: id, create: create)
    }
    /// Per-app configuration directory — where the settings file lives (created unless `create: false`).
    public static func configuration(for id: AppIdentity, create: Bool = true) throws -> URL {
        try resolve(.configuration, id: id, create: create)
    }
    /// Per-app cache directory (created unless `create: false`).
    public static func caches(for id: AppIdentity, create: Bool = true) throws -> URL {
        try resolve(.caches, id: id, create: create)
    }
    /// A fresh, unique temporary directory (process-scoped; not identity-namespaced).
    public static func temporary() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    enum Kind: Sendable { case applicationSupport, configuration, caches }

    static func resolve(_ kind: Kind, id: AppIdentity, create: Bool) throws -> URL {
        var url = try baseURL(kind).appendingPathComponent(id.identifier, isDirectory: true)
        if isWindows, kind == .caches {
            url.appendPathComponent("Cache", isDirectory: true)   // Windows has no separate cache root
        }
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// The OS base directory (before the app-id subcomponent) for a kind.
    static func baseURL(_ kind: Kind) throws -> URL {
        #if canImport(Darwin)
        let search: FileManager.SearchPathDirectory = (kind == .caches) ? .cachesDirectory : .applicationSupportDirectory
        return try FileManager.default.url(for: search, in: .userDomainMask, appropriateFor: nil, create: false)
        #elseif os(Windows)
        let env = ProcessInfo.processInfo.environment
        guard let path = windowsPath(kind, env: env) else {
            throw StorageError.missingEnvironment(kind == .configuration ? "APPDATA" : "LOCALAPPDATA")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: xdgPath(kind, env: env, home: home), isDirectory: true)
        #endif
    }

    static var isWindows: Bool {
        #if os(Windows)
        return true
        #else
        return false
        #endif
    }

    /// Pure XDG base-directory resolution (host-testable). Per the spec, a relative value in an XDG_*_HOME
    /// variable is invalid and ignored (treated as unset), falling back to the `~`-relative default.
    static func xdgPath(_ kind: Kind, env: [String: String], home: String) -> String {
        let variable: String, fallback: String
        switch kind {
        case .applicationSupport: variable = "XDG_DATA_HOME";   fallback = ".local/share"
        case .configuration:      variable = "XDG_CONFIG_HOME"; fallback = ".config"
        case .caches:             variable = "XDG_CACHE_HOME";  fallback = ".cache"
        }
        if let value = env[variable], value.hasPrefix("/") { return value }
        return "\(home)/\(fallback)"
    }

    /// Pure Windows base-directory resolution (host-testable). Config is roaming (%APPDATA%); data/cache are
    /// local (%LOCALAPPDATA%); the cache gets a `\Cache` subfolder appended by `resolve`.
    static func windowsPath(_ kind: Kind, env: [String: String]) -> String? {
        switch kind {
        case .configuration: return env["APPDATA"]
        case .applicationSupport, .caches: return env["LOCALAPPDATA"]
        }
    }
}
