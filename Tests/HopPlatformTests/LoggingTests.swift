// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Logging is apple/swift-log; HopPlatform only adds the OS-native handlers + the bootstrap selector, so
// these tests cover exactly that (the facade itself is swift-log's to test). We do NOT call
// LoggingSystem.bootstrap here — it's a one-shot process global — instead exercising the factory + handlers
// directly.

import Testing
import Logging
#if canImport(os)
import os
#endif
@testable import HopPlatform

@Suite struct HopLoggingTests {
    @Test func envLogLevelParsing() {
        #expect(HopLogging.envLogLevel(["HOP_LOG_LEVEL": "debug"]) == .debug)
        #expect(HopLogging.envLogLevel(["HOP_LOG_LEVEL": "WARNING"]) == .warning)   // case-insensitive
        #expect(HopLogging.envLogLevel(["HOP_LOG_LEVEL": "critical"]) == .critical)
        #expect(HopLogging.envLogLevel([:]) == .info)                                // default
        #expect(HopLogging.envLogLevel(["HOP_LOG_LEVEL": "nonsense"]) == .info)      // invalid → default
    }

    @Test func defaultHandlerIsOSNative() {
        let handler = HopLogging.makeOSHandler(subsystem: "dev.hop.test", category: "sel")
        #if canImport(os)
        #expect(handler is OSLogHandler)
        #elseif os(Linux)
        #expect(handler is JournaldLogHandler)
        #elseif os(Windows)
        #expect(handler is WindowsLogHandler)
        #endif
        #expect(handler.logLevel == .info)
    }

    #if canImport(os)
    @Test func osLogLevelMapping() {
        #expect(OSLogHandler.osType(for: .trace) == .debug)
        #expect(OSLogHandler.osType(for: .debug) == .debug)
        #expect(OSLogHandler.osType(for: .info) == .info)
        #expect(OSLogHandler.osType(for: .notice) == .default)
        #expect(OSLogHandler.osType(for: .warning) == .error)
        #expect(OSLogHandler.osType(for: .critical) == .fault)
    }

    @Test func osLogComposeAppendsMetadata() {
        #expect(OSLogHandler.compose("hi", [:]) == "hi")
        #expect(OSLogHandler.compose("hi", ["b": "2", "a": "1"]) == "hi a=1 b=2")   // sorted by key
    }

    @Test func osLogHandlerSmoke() {
        // Can't read the unified log here; just drive the os_log path across all levels without crashing.
        var handler = OSLogHandler(subsystem: "dev.hop.test", category: "smoke")
        handler.logLevel = .trace
        handler.metadata["app"] = "hop"
        for level in Logging.Logger.Level.allCases {
            handler.log(event: LogEvent(level: level, message: "msg \(level.rawValue)",
                                        metadata: ["k": .stringConvertible(level.rawValue)],
                                        source: "test", file: #fileID, function: #function, line: #line))
        }
    }
    #endif
}
