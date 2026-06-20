// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import HopPlatform

@Suite struct StorageLocationTests {
    // Pure XDG resolution — testable on any host (the wiring is gated to Linux, the logic is not).
    @Test func xdgHonorsEnvironment() {
        let env = ["XDG_DATA_HOME": "/data", "XDG_CONFIG_HOME": "/cfg", "XDG_CACHE_HOME": "/cache"]
        #expect(StorageLocations.xdgPath(.applicationSupport, env: env, home: "/home/u") == "/data")
        #expect(StorageLocations.xdgPath(.configuration, env: env, home: "/home/u") == "/cfg")
        #expect(StorageLocations.xdgPath(.caches, env: env, home: "/home/u") == "/cache")
    }

    @Test func xdgFallsBackWhenUnset() {
        #expect(StorageLocations.xdgPath(.applicationSupport, env: [:], home: "/home/u") == "/home/u/.local/share")
        #expect(StorageLocations.xdgPath(.configuration, env: [:], home: "/home/u") == "/home/u/.config")
        #expect(StorageLocations.xdgPath(.caches, env: [:], home: "/home/u") == "/home/u/.cache")
    }

    @Test func xdgIgnoresRelativeValues() {
        // The XDG spec says a relative value is invalid and must be ignored (treated as unset).
        let env = ["XDG_CONFIG_HOME": "relative/cfg"]
        #expect(StorageLocations.xdgPath(.configuration, env: env, home: "/home/u") == "/home/u/.config")
    }

    // Pure Windows resolution — config roams (%APPDATA%), data/cache are local (%LOCALAPPDATA%).
    @Test func windowsUsesAppDataVariables() {
        let env = ["APPDATA": #"C:\Users\u\AppData\Roaming"#, "LOCALAPPDATA": #"C:\Users\u\AppData\Local"#]
        #expect(StorageLocations.windowsPath(.configuration, env: env) == #"C:\Users\u\AppData\Roaming"#)
        #expect(StorageLocations.windowsPath(.applicationSupport, env: env) == #"C:\Users\u\AppData\Local"#)
        #expect(StorageLocations.windowsPath(.caches, env: env) == #"C:\Users\u\AppData\Local"#)
        #expect(StorageLocations.windowsPath(.configuration, env: [:]) == nil)
    }

    // Host (Apple) path: shape is correct without writing anything.
    @Test func applePathShape() throws {
        let id = AppIdentity(identifier: "dev.hop.storagetest", name: "Storage Test")
        let support = try StorageLocations.applicationSupport(for: id, create: false)
        #expect(support.lastPathComponent == "dev.hop.storagetest")
        #if canImport(Darwin)
        #expect(support.path.contains("Application Support"))
        let caches = try StorageLocations.caches(for: id, create: false)
        #expect(caches.path.contains("Caches"))
        #endif
    }

    @Test func createMakesDirectory() throws {
        let id = AppIdentity(identifier: "dev.hop.test.\(UUID().uuidString)", name: "T")
        let dir = try StorageLocations.applicationSupport(for: id, create: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func temporaryIsFreshAndExists() {
        let a = StorageLocations.temporary()
        let b = StorageLocations.temporary()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(a != b)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
}
