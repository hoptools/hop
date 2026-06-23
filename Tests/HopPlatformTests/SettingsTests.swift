// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import HopPlatform

@Suite struct SettingsStoreTests {
    /// A fresh store backed by a unique temp file, cleaned up after `body`.
    private func withTempStore(_ body: (FileSettingsStore, URL) throws -> Void) rethrows {
        let url = StorageLocations.temporary().appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try body(FileSettingsStore(fileURL: url), url)
    }

    struct Profile: Codable, Sendable, Equatable { var name: String; var age: Int; var tags: [String] }

    @Test func roundTripsScalarsAndStructs() throws {
        try withTempStore { store, _ in
            store.set(true, forKey: "enabled")
            store.set(42, forKey: "count")
            store.set(3.5, forKey: "ratio")
            store.set("hello", forKey: "greeting")
            store.set([1, 2, 3], forKey: "nums")
            store.set(Profile(name: "Ada", age: 36, tags: ["x", "y"]), forKey: "profile")

            #expect(store.value(Bool.self, forKey: "enabled") == true)
            #expect(store.value(Int.self, forKey: "count") == 42)
            #expect(store.value(Double.self, forKey: "ratio") == 3.5)
            #expect(store.value(String.self, forKey: "greeting") == "hello")
            #expect(store.value([Int].self, forKey: "nums") == [1, 2, 3])
            #expect(store.value(Profile.self, forKey: "profile") == Profile(name: "Ada", age: 36, tags: ["x", "y"]))
            // Type-inferred convenience.
            let count: Int? = store.value(forKey: "count")
            #expect(count == 42)
        }
    }

    @Test func missingKeyAndTypeMismatchReturnNil() throws {
        try withTempStore { store, _ in
            #expect(store.value(Int.self, forKey: "nope") == nil)
            store.set("not a number", forKey: "k")
            #expect(store.value(Int.self, forKey: "k") == nil)        // wrong type → nil, not a crash
            #expect(store.value(String.self, forKey: "k") == "not a number")
        }
    }

    @Test func removeDeletesValue() throws {
        try withTempStore { store, _ in
            store.set(1, forKey: "k")
            store.removeValue(forKey: "k")
            #expect(store.value(Int.self, forKey: "k") == nil)
        }
    }

    @Test func persistsAcrossReopen() throws {
        let url = StorageLocations.temporary().appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = FileSettingsStore(fileURL: url)
            store.set("persisted", forKey: "k")
            store.set(7, forKey: "n")
        }
        #expect(FileManager.default.fileExists(atPath: url.path))    // wrote a real file
        let reopened = FileSettingsStore(fileURL: url)
        #expect(reopened.value(String.self, forKey: "k") == "persisted")
        #expect(reopened.value(Int.self, forKey: "n") == 7)
        // File is plain, human-readable JSON.
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("persisted"))
    }

    @Test func observeFiresOnChangeAndStopsAfterCancel() throws {
        try withTempStore { store, _ in
            let hits = Hits()
            let token = store.observe("watched", onChange: { hits.bump() })
            store.set(1, forKey: "watched")
            store.set(2, forKey: "watched")
            store.set(9, forKey: "unwatched")          // different key → no fire
            #expect(hits.count == 2)
            token.cancel()
            store.set(3, forKey: "watched")            // cancelled → no fire
            #expect(hits.count == 2)
            _ = token                                   // keep alive until here
        }
    }
}

#if canImport(Darwin)
/// `UserDefaultsSettingsStore` — the Apple-native backend. Uses an isolated suite (not `.standard`) so the
/// test never touches real preferences, and removes it afterward.
@Suite struct UserDefaultsSettingsStoreTests {
    private func withSuite(_ body: (UserDefaultsSettingsStore, String) throws -> Void) rethrows {
        let suite = "dev.hop.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try body(UserDefaultsSettingsStore(suiteName: suite), suite)
    }

    @Test func roundTripsNativePlistTypes() throws {
        try withSuite { store, suite in
            store.set(true, forKey: "enabled")
            store.set(42, forKey: "count")
            store.set(3.5, forKey: "ratio")
            store.set("hello", forKey: "greeting")
            #expect(store.value(Bool.self, forKey: "enabled") == true)
            #expect(store.value(Int.self, forKey: "count") == 42)
            #expect(store.value(Double.self, forKey: "ratio") == 3.5)
            #expect(store.value(String.self, forKey: "greeting") == "hello")
            #expect(store.value(Int.self, forKey: "absent") == nil)   // missing ≠ 0
            // Stored NATIVELY (not a Data blob), so the suite's UserDefaults sees it directly — proving
            // ecosystem visibility (`defaults read`, App Groups, etc.).
            #expect(UserDefaults(suiteName: suite)?.integer(forKey: "count") == 42)
        }
    }

    @Test func notifiesObserverOnWrite() throws {
        try withSuite { store, _ in
            let hits = Hits()
            let token = store.observe("k") { hits.bump() }
            store.set(1, forKey: "k")
            store.set(2, forKey: "k")
            #expect(hits.count == 2)
            _ = token
        }
    }
}
#endif

// Thread-safe counter (observer callbacks are @Sendable).
private final class Hits: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func bump() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}
