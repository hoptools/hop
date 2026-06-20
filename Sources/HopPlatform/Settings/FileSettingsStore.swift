// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The portable default SettingsStore: a single plain-JSON file (atomic writes) in the app's config dir.
// Uniform on every OS, no schema, human-readable/-editable. Values bridge through JSONValue so the file is
// real JSON. All state is behind a Mutex, so the store is Sendable and safe from any thread.

import Foundation
import Synchronization

public final class FileSettingsStore: SettingsStore {
    private let fileURL: URL

    private struct State {
        var values: [String: JSONValue]
        var observers: [String: [UInt64: @Sendable () -> Void]] = [:]
        var nextToken: UInt64 = 0
    }
    private let state: Mutex<State>

    /// Back the store with an explicit JSON file (loaded if it exists). The parent directory is created on
    /// first write.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        self.state = Mutex(State(values: loaded))
    }

    /// Back the store with `<config dir>/<fileName>` for the app (config dir created eagerly).
    public convenience init(for id: AppIdentity, fileName: String = "settings.json") throws {
        let dir = try StorageLocations.configuration(for: id)
        self.init(fileURL: dir.appendingPathComponent(fileName, isDirectory: false))
    }

    public func value<T: Codable & Sendable>(_ type: T.Type, forKey key: String) -> T? {
        guard let json = state.withLock({ $0.values[key] }) else { return nil }
        return Self.decode(json, as: T.self)
    }

    public func set<T: Codable & Sendable>(_ value: T, forKey key: String) {
        guard let json = Self.encode(value) else { return }
        notify(state.withLock { st in
            st.values[key] = json
            Self.persist(st.values, to: fileURL)
            return Array((st.observers[key] ?? [:]).values)
        })
    }

    public func removeValue(forKey key: String) {
        notify(state.withLock { st in
            st.values.removeValue(forKey: key)
            Self.persist(st.values, to: fileURL)
            return Array((st.observers[key] ?? [:]).values)
        })
    }

    public func observe(_ key: String, onChange: @escaping @Sendable () -> Void) -> SettingsCancellable {
        let token = state.withLock { st -> UInt64 in
            let token = st.nextToken
            st.nextToken += 1
            st.observers[key, default: [:]][token] = onChange
            return token
        }
        return SettingsCancellable { [weak self] in
            self?.state.withLock { _ = $0.observers[key]?.removeValue(forKey: token) }
        }
    }

    private func notify(_ observers: [@Sendable () -> Void]) {
        observers.forEach { $0() }   // fire OUTSIDE the lock to avoid re-entrancy deadlocks
    }

    // MARK: Typed ↔ JSONValue bridging (array-wrapped to sidestep top-level-fragment limits across platforms)

    static func encode<T: Codable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode([value]),
              let wrapped = try? JSONDecoder().decode([JSONValue].self, from: data) else { return nil }
        return wrapped.first
    }

    static func decode<T: Codable>(_ json: JSONValue, as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode([json]),
              let wrapped = try? JSONDecoder().decode([T].self, from: data) else { return nil }
        return wrapped.first
    }

    static func persist(_ values: [String: JSONValue], to url: URL) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
