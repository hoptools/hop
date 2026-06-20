// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The per-application settings (preferences) abstraction. `FileSettingsStore` is the portable default — a
// plain-JSON file in the app's config dir, uniform across every OS with no schema. Native-store backends
// (UserDefaults / GSettings / ApplicationData) can adopt this protocol later; a reactive `@AppStorage`-style
// wrapper belongs in HopUI (it needs the render graph), built on top of this.

import Synchronization

/// A typed, observable key→value preference store. `Sendable` — callable from any isolation.
public protocol SettingsStore: Sendable {
    /// The stored value for `key` decoded as `T`, or nil if absent / type-incompatible.
    func value<T: Codable & Sendable>(_ type: T.Type, forKey key: String) -> T?
    /// Store `value` for `key` (overwriting), persisting and notifying observers of that key.
    func set<T: Codable & Sendable>(_ value: T, forKey key: String)
    /// Remove any value for `key`, persisting and notifying observers of that key.
    func removeValue(forKey key: String)
    /// Observe changes to `key`. Retain the returned token to keep observing; it stops on `cancel()` or when
    /// the token is released.
    func observe(_ key: String, onChange: @escaping @Sendable () -> Void) -> SettingsCancellable
}

public extension SettingsStore {
    /// Type-inferred convenience: `let n: Int? = store.value(forKey: "count")`.
    func value<T: Codable & Sendable>(forKey key: String) -> T? { value(T.self, forKey: key) }
}

/// Cancels a settings observation. Cancels automatically when released (Combine-style), so hold onto it for
/// as long as the observation should live.
public final class SettingsCancellable: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    init(_ action: @escaping @Sendable () -> Void) { self.action = Mutex(action) }

    /// Stop the observation. Idempotent.
    public func cancel() {
        let action = self.action.withLock { stored -> (@Sendable () -> Void)? in
            let value = stored
            stored = nil
            return value
        }
        action?()
    }

    deinit { cancel() }
}
