// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The idiomatic Apple preferences backend for `SettingsStore` — `UserDefaults`, which is exactly what
// SwiftUI's `@AppStorage` uses. The whole Apple ecosystem assumes prefs live here: the `defaults` CLI,
// System Settings, App Groups (widgets/extensions), iCloud key-value sync, and MDM managed config all read
// `UserDefaults`. The property-list-native types (Bool/Int/Double/String/Data/URL) are stored DIRECTLY so
// `defaults read <bundle-id>` shows them and the ecosystem can see them; other Codable types fall back to a
// plist-encoded blob. (On non-Apple OSes, `FileSettingsStore` — an XDG/%APPDATA% config file — is the
// idiomatic default instead; see `makeDefaultSettingsStore`.)

#if canImport(Darwin)
import Foundation
import Synchronization

public final class UserDefaultsSettingsStore: SettingsStore {
    /// The suite name (nil ⇒ `.standard`). Stored instead of the `UserDefaults` instance so the class stays
    /// `Sendable` with no `@unchecked` — `UserDefaults` is a thread-safe process singleton resolved per call.
    private let suiteName: String?
    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private struct State {
        var observers: [String: [UInt64: @Sendable () -> Void]] = [:]
        var nextToken: UInt64 = 0
    }
    private let state: Mutex<State>

    /// `nil` suite ⇒ `UserDefaults.standard` (the app's own domain, keyed by its bundle id). Pass an App
    /// Group suite name to share preferences with extensions/widgets.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
        self.state = Mutex(State())
    }

    public func value<T: Codable & Sendable>(_ type: T.Type, forKey key: String) -> T? {
        let defaults = self.defaults
        guard defaults.object(forKey: key) != nil else { return nil }   // distinguish "absent" from "false/0"
        // Read the property-list-native types directly (the common @AppStorage types + RawRepresentable raws).
        if type == Bool.self { return defaults.bool(forKey: key) as? T }
        if type == Int.self { return defaults.integer(forKey: key) as? T }
        if type == Double.self { return defaults.double(forKey: key) as? T }
        if type == String.self { return defaults.string(forKey: key) as? T }
        if type == Data.self { return defaults.data(forKey: key) as? T }
        if type == URL.self { return defaults.url(forKey: key) as? T }
        // Other Codable types: a plist-encoded Data blob (array-wrapped to sidestep top-level-fragment limits).
        guard let data = defaults.data(forKey: key),
              let wrapped = try? PropertyListDecoder().decode([T].self, from: data) else { return nil }
        return wrapped.first
    }

    public func set<T: Codable & Sendable>(_ value: T, forKey key: String) {
        let defaults = self.defaults
        switch value {
        case let v as Bool: defaults.set(v, forKey: key)
        case let v as Int: defaults.set(v, forKey: key)
        case let v as Double: defaults.set(v, forKey: key)
        case let v as String: defaults.set(v, forKey: key)
        case let v as Data: defaults.set(v, forKey: key)
        case let v as URL: defaults.set(v, forKey: key)
        default:
            guard let data = try? PropertyListEncoder().encode([value]) else { return }
            defaults.set(data, forKey: key)
        }
        notify(observersOf: key)
    }

    public func removeValue(forKey key: String) {
        defaults.removeObject(forKey: key)
        notify(observersOf: key)
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

    // Notifies observers of this store's OWN writes (matching FileSettingsStore — external `defaults write`
    // from another process is not observed; @AppStorage's reactivity comes from the render graph, not here).
    private func notify(observersOf key: String) {
        let callbacks = state.withLock { Array(($0.observers[key] ?? [:]).values) }
        callbacks.forEach { $0() }   // fire outside the lock to avoid re-entrancy deadlocks
    }
}
#endif
