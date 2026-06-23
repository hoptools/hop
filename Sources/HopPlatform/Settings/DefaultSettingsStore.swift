// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// OS-keyed selection of the idiomatic default `SettingsStore` — the QSettings model: one protocol, the
// platform-native store behind it. On Apple, `UserDefaults` (what `@AppStorage` ecosystem tooling expects).
// On Linux, a JSON config file in `XDG_CONFIG_HOME` — the freedesktop convention (GSettings needs a compiled,
// installed schema, which breaks dev/unpackaged/Flatpak runs and is GNOME-specific). On Windows, a config
// file in `%APPDATA%` — `ApplicationData.LocalSettings` requires package identity, which an unpackaged
// (MddBootstrap) app doesn't have. `FileSettingsStore` already lands in the right per-OS dir via
// `StorageLocations`, so it's the correct non-Apple default; a registry backend can be added later.

import Foundation

/// The idiomatic default preferences store for the running OS. Apple ⇒ `UserDefaults`; elsewhere ⇒ a
/// `FileSettingsStore` in the app's config dir. Always succeeds (falls back to a temp-file store if the
/// config dir can't be created).
public func makeDefaultSettingsStore(for id: AppIdentity) -> SettingsStore {
    #if canImport(Darwin)
    // UserDefaults.standard is keyed by the app's bundle id automatically — `id` is only used for the
    // file-based stores' on-disk path, so it's intentionally unused here.
    return UserDefaultsSettingsStore()
    #else
    if let store = try? FileSettingsStore(for: id) { return store }
    return FileSettingsStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("\(id.identifier)-settings.json", isDirectory: false))
    #endif
}
