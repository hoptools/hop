// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Logging in Hop is apple/swift-log — the standard Swift facade. HopPlatform does NOT reimplement the
// `Logger` / `LogHandler` / `Logger.Level` / `MultiplexLogHandler` / stream-handler machinery; it adds only
// what swift-log lacks: OS-native `LogHandler`s (os_log / journald / OutputDebugString) and a one-call
// bootstrap that routes swift-log through them. App code just uses `import Logging` + `Logger(label:)`.

import Foundation
import Logging

public enum HopLogging {
    /// Route swift-log through the OS-native sink (os_log on Apple, journald on Linux, OutputDebugString on
    /// Windows) under a single app `subsystem`; each `Logger(label:)`'s label becomes the os_log category /
    /// journald `HOP_CATEGORY`. Call ONCE at startup — swift-log's bootstrap is one-shot, and apps that want
    /// their own handler should call `LoggingSystem.bootstrap` directly instead. Honors `HOP_LOG_LEVEL`.
    public static func bootstrap(subsystem: String) {
        let level = envLogLevel(ProcessInfo.processInfo.environment)
        LoggingSystem.bootstrap { label in
            var handler = makeOSHandler(subsystem: subsystem, category: label)
            handler.logLevel = level
            return handler
        }
    }

    /// The OS-native `LogHandler` for a subsystem/category, chosen at compile time. Falls back to swift-log's
    /// own stderr stream handler on platforms without a native sink.
    static func makeOSHandler(subsystem: String, category: String) -> any LogHandler {
        #if canImport(os)
        return OSLogHandler(subsystem: subsystem, category: category)
        #elseif os(Linux)
        return JournaldLogHandler(subsystem: subsystem, category: category)
        #elseif os(Windows)
        return WindowsLogHandler(subsystem: subsystem, category: category)
        #else
        return StreamLogHandler.standardError(label: category)
        #endif
    }

    /// `HOP_LOG_LEVEL` (trace|debug|info|notice|warning|error|critical, case-insensitive) → level; `.info`
    /// otherwise. Pure for testability — swift-log's `Logger.Level` is `String`-raw, so this just validates it.
    static func envLogLevel(_ environment: [String: String]) -> Logging.Logger.Level {
        if let raw = environment["HOP_LOG_LEVEL"], let level = Logging.Logger.Level(rawValue: raw.lowercased()) {
            return level
        }
        return .info
    }
}
