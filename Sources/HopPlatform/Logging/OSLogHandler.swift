// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// swift-log LogHandler backed by Apple os_log. The logger's swift-log `label` becomes the os_log category
// under a fixed app subsystem (see HopLogging.bootstrap), so Console.app groups records by category.
// swift-log has no privacy model, so messages are emitted as os_log public (a dynamic string is otherwise
// private-by-default and would show as `<private>`); apps needing native redaction can log via os_log directly.

#if canImport(os)
import os
import Logging

public struct OSLogHandler: LogHandler {
    public var logLevel: Logging.Logger.Level = .info
    public var metadata: Logging.Logger.Metadata = [:]
    private let osLogger: os.Logger

    public init(subsystem: String, category: String) {
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        let text = Self.compose("\(event.message)", merged(event.metadata))
        osLogger.log(level: Self.osType(for: event.level), "\(text, privacy: .public)")
    }

    /// Per-call metadata layered over the handler's standing metadata.
    func merged(_ explicit: Logging.Logger.Metadata?) -> Logging.Logger.Metadata {
        guard let explicit, !explicit.isEmpty else { return metadata }
        return metadata.merging(explicit) { _, new in new }
    }

    static func compose(_ message: String, _ metadata: Logging.Logger.Metadata) -> String {
        guard !metadata.isEmpty else { return message }
        let pairs = metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(message) \(pairs)"
    }

    static func osType(for level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning, .error: return .error
        case .critical: return .fault
        }
    }
}
#endif
