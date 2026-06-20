// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// swift-log LogHandler for Windows, routing to OutputDebugStringW (visible in the debugger / DebugView / VS
// Output window) — reliable, no provider registration, no C shim (WinSDK is toolchain-implicit). A structured
// ETW TraceLogging provider is the planned upgrade (it needs a C/C++ macro shim). Gated to Windows →
// validated by the Windows CI job, not host-locally.

#if os(Windows)
import Logging
import WinSDK

public struct WindowsLogHandler: LogHandler {
    public var logLevel: Logging.Logger.Level = .info
    public var metadata: Logging.Logger.Metadata = [:]
    private let subsystem: String
    private let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        var line = "[\(subsystem):\(category)] \(event.level.rawValue) \(event.message)"
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        if !merged.isEmpty {
            line += " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        line += "\r\n"
        line.withCString(encodedAs: UTF16.self) { OutputDebugStringW($0) }
    }
}
#endif
