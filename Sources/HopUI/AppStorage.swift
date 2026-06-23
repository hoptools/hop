// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation
import HopGraph
import HopPlatform

// `@AppStorage` — a persisted, reactive preference, mirroring SwiftUI's `@AppStorage`. Unlike `@State` (which
// is per-view-identity), an `@AppStorage` key is APP-GLOBAL: every view reading the same key shares one value
// and they all re-render together when it changes. Persistence is via HopPlatform's `FileSettingsStore` (a
// JSON file in the app's config dir) rather than SwiftUI's `UserDefaults`. Reactivity reuses the same graph
// source mechanism as `@State`: reading registers a dependency on the reading composite; writing invalidates
// every reader and schedules one coalesced flush (and persists to the store).

/// The process-wide store backing `@AppStorage` keys with no explicit `store:`. Set it once at launch to use a
/// custom store; tests point it at an isolated store. Reachable without a concrete `Value` (unlike a static on
/// the generic `AppStorage` type).
@MainActor
public enum AppStorageConfiguration {
    /// The default store. Setting it clears the cached key sources so the new store takes effect immediately.
    public static var defaultStore: SettingsStore {
        get { AppStorageRegistry.defaultStore }
        set { AppStorageRegistry.defaultStore = newValue; AppStorageRegistry.reset() }
    }
}

/// App-global registry of per-key reactive sources, shared by every `@AppStorage` reading that key. The cached
/// boxes' graph sources belong to the current app graph, so they're cleared when a new app graph is installed
/// (see `GraphContext.resetForNewApp`).
@MainActor
enum AppStorageRegistry {
    private static var boxes: [String: AnyObject] = [:]

    static func box<Value>(key: String, make: () -> AppStorageBox<Value>) -> AppStorageBox<Value> {
        if let existing = boxes[key] as? AppStorageBox<Value> { return existing }
        let created = make()
        boxes[key] = created
        return created
    }

    /// Drop all cached key sources — their `Attribute`s belong to a graph that's being replaced.
    static func reset() { boxes.removeAll() }

    /// Snapshot/restore the cached boxes, so a secondary window can evaluate its content against a throwaway
    /// graph in isolation (fresh boxes) and then hand the main window's boxes — with their live graph sources
    /// and dependency edges intact — back unchanged. (A plain `reset()` after the fact would orphan the main
    /// readers' edges; save/restore preserves them.)
    static func snapshot() -> [String: AnyObject] { boxes }
    static func restore(_ saved: [String: AnyObject]) { boxes = saved }

    // The OS-idiomatic default store: UserDefaults on Apple, an XDG/%APPDATA% config file elsewhere (see
    // HopPlatform.makeDefaultSettingsStore). On Apple, `id` is unused (UserDefaults.standard keys off the bundle).
    static var defaultStore: SettingsStore = makeDefaultSettingsStore(
        for: AppIdentity(identifier: Bundle.main.bundleIdentifier ?? "dev.hop.app", name: "Hop"))
}

/// Reference-typed backing for one `@AppStorage` key: the graph source (lazily created in the current graph)
/// plus the closure that persists writes. `nonisolated` for the same reason as `State.Box` (avoids a Swift 6.3
/// SILGen crash synthesizing an isolating deinit for a generic class); only ever touched on the main loop.
nonisolated final class AppStorageBox<Value> {
    private let initial: Value
    let persist: (Value) -> Void
    private var graphSource: Attribute<Value>?
    init(initial: Value, persist: @escaping (Value) -> Void) { self.initial = initial; self.persist = persist }

    func source(in graph: Graph) -> Attribute<Value> {
        if let graphSource { return graphSource }
        let created = graph.makeSource(initial)
        graphSource = created
        return created
    }
}

@propertyWrapper
public struct AppStorage<Value> {
    private let box: AppStorageBox<Value>
    private init(box: AppStorageBox<Value>) { self.box = box }

    public var wrappedValue: Value {
        get {
            let graph = GraphContext.requireCurrent()
            return graph.read(box.source(in: graph))   // registers a dependency on the reading composite
        }
        nonmutating set {
            let graph = GraphContext.requireCurrent()
            graph.setValue(newValue, for: box.source(in: graph))   // invalidates every reader of this key
            box.persist(newValue)                                  // write through to the store
            GraphContext.scheduleFlush()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
    }
}

// MARK: - Initializers (matching SwiftUI's @AppStorage overload set, for dual-compile)

extension AppStorage {
    /// Shared backing for the concrete `Codable & Sendable` value types below. Kept as an internal helper
    /// (NOT a public generic `where Value: Codable & Sendable` init) so it can't collide with the
    /// `RawRepresentable` inits for a type that conforms to both — matching SwiftUI's concrete-overload set.
    fileprivate init(codable wrappedValue: Value, _ key: String, store: SettingsStore?)
        where Value: Codable & Sendable {
        let store = store ?? AppStorageRegistry.defaultStore
        self.init(box: AppStorageRegistry.box(key: key) {
            let initial = store.value(Value.self, forKey: key) ?? wrappedValue
            return AppStorageBox(initial: initial, persist: { store.set($0, forKey: key) })
        })
    }
}

// SwiftUI's @AppStorage has one concrete init per supported value type (not a generic `Codable`), so a
// `RawRepresentable` enum matches ONLY the RawRepresentable inits below — no ambiguity.
public extension AppStorage where Value == Bool {
    init(wrappedValue: Value, _ key: String, store: SettingsStore? = nil) { self.init(codable: wrappedValue, key, store: store) }
}
public extension AppStorage where Value == Int {
    init(wrappedValue: Value, _ key: String, store: SettingsStore? = nil) { self.init(codable: wrappedValue, key, store: store) }
}
public extension AppStorage where Value == Double {
    init(wrappedValue: Value, _ key: String, store: SettingsStore? = nil) { self.init(codable: wrappedValue, key, store: store) }
}
public extension AppStorage where Value == String {
    init(wrappedValue: Value, _ key: String, store: SettingsStore? = nil) { self.init(codable: wrappedValue, key, store: store) }
}
public extension AppStorage where Value == URL {
    init(wrappedValue: Value, _ key: String, store: SettingsStore? = nil) { self.init(codable: wrappedValue, key, store: store) }
}
public extension AppStorage where Value == Data {
    init(wrappedValue: Value, _ key: String, store: SettingsStore? = nil) { self.init(codable: wrappedValue, key, store: store) }
}

public extension AppStorage where Value: RawRepresentable, Value.RawValue == Int {
    /// A persisted `RawRepresentable` (Int-raw, e.g. an enum), stored as its raw value. Mirrors SwiftUI.
    init(wrappedValue: Value, _ key: String, store: SettingsStore? = nil) {
        let store = store ?? AppStorageRegistry.defaultStore
        self.init(box: AppStorageRegistry.box(key: key) {
            let initial = store.value(Int.self, forKey: key).flatMap(Value.init(rawValue:)) ?? wrappedValue
            return AppStorageBox(initial: initial, persist: { store.set($0.rawValue, forKey: key) })
        })
    }
}

public extension AppStorage where Value: RawRepresentable, Value.RawValue == String {
    /// A persisted `RawRepresentable` (String-raw, e.g. an enum), stored as its raw value. Mirrors SwiftUI.
    init(wrappedValue: Value, _ key: String, store: SettingsStore? = nil) {
        let store = store ?? AppStorageRegistry.defaultStore
        self.init(box: AppStorageRegistry.box(key: key) {
            let initial = store.value(String.self, forKey: key).flatMap(Value.init(rawValue:)) ?? wrappedValue
            return AppStorageBox(initial: initial, persist: { store.set($0.rawValue, forKey: key) })
        })
    }
}
