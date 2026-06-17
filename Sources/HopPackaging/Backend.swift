// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Platform behavior lives behind a `PlatformBackend`, selected by the target OS. Stages stay platform-
// agnostic and delegate the OS-specific work (laying out a bundle, launching, producing a distribution)
// to the backend. Adding a new platform is "write a backend + register it"; adding a new step is "write
// a Stage". The two axes compose.

/// The platform-specific half of packaging: how to process resources, lay out the app, launch it, and
/// produce the idiomatic distribution for one operating system.
public protocol PlatformBackend: Sendable {
    /// The OS this backend targets.
    var os: OS { get }
    /// The idiomatic distribution format this backend produces (e.g. "dmg", "flatpak", "msix").
    var distributionFormat: String { get }

    /// Stage resources (icons, declared resource files) into the work directory; set `resourcesDirectory`.
    func processResources(_ context: PackagingContext) async throws -> PackagingContext
    /// Lay out the platform application from the built executable + resources + metadata; set `appArtifact`.
    func assembleApp(_ context: PackagingContext) async throws -> PackagingContext
    /// Launch the assembled application the idiomatic way for the platform.
    func launch(_ context: PackagingContext) async throws
    /// Bundle the assembled application into the platform's distribution format; set `packageArtifact`.
    func packageApp(_ context: PackagingContext) async throws -> PackagingContext
}

/// Selects the `PlatformBackend` for a target OS. A simple, total mapping today; structured as a single
/// lookup so additional/overriding backends can be slotted in later without touching call sites.
public enum BackendRegistry {
    public static func backend(for os: OS) -> any PlatformBackend {
        switch os {
        case .macos: return MacOSBackend()
        case .linux: return LinuxBackend()
        case .windows: return WindowsBackend()
        }
    }
}
