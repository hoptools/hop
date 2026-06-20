// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// swift-log LogHandler backed by systemd-journald (Linux). Emits a structured record via sd_journal_sendv
// (libsystemd, via the Csystemd systemLibrary), so logs land in `journalctl` with MESSAGE/PRIORITY/CODE_*
// fields and metadata as custom HOP_* fields. Gated to Linux → validated by the Linux CI job, not host-locally.

#if os(Linux)
import Logging
import Csystemd
import Glibc

public struct JournaldLogHandler: LogHandler {
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
        var fields = [
            "MESSAGE=\(event.message)",
            "PRIORITY=\(Self.priority(for: event.level))",
            "SYSLOG_IDENTIFIER=\(subsystem)",
            "HOP_CATEGORY=\(category)",
            "CODE_FILE=\(event.file)",
            "CODE_FUNC=\(event.function)",
            "CODE_LINE=\(event.line)",
        ]
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        for key in merged.keys.sorted() {
            fields.append("\(Self.journalField(key))=\(merged[key]!)")
        }
        Self.send(fields)
    }

    /// syslog priority levels (0=emerg … 7=debug) that journald expects in the PRIORITY field.
    static func priority(for level: Logging.Logger.Level) -> Int32 {
        switch level {
        case .trace, .debug: return 7   // LOG_DEBUG
        case .info: return 6            // LOG_INFO
        case .notice: return 5          // LOG_NOTICE
        case .warning: return 4         // LOG_WARNING
        case .error: return 3           // LOG_ERR
        case .critical: return 2        // LOG_CRIT
        }
    }

    /// journald field names must be uppercase [A–Z0–9_] and not start with a digit; prefix custom keys so
    /// they're namespaced and always valid.
    static func journalField(_ key: String) -> String {
        var out = "HOP_"
        for ch in key.uppercased() {
            out.append(ch.isLetter || ch.isNumber ? ch : "_")
        }
        return out
    }

    /// Copy each "FIELD=VALUE" into a C buffer, point an iovec at it, and hand the batch to sd_journal_sendv.
    static func send(_ fields: [String]) {
        let copies = fields.compactMap { strdup($0) }   // owned C strings; freed below
        defer { copies.forEach { free($0) } }
        var iov = copies.map { ptr in
            iovec(iov_base: UnsafeMutableRawPointer(ptr), iov_len: Int(strlen(ptr)))
        }
        _ = iov.withUnsafeBufferPointer { buffer in
            sd_journal_sendv(buffer.baseAddress, Int32(buffer.count))
        }
    }
}
#endif
