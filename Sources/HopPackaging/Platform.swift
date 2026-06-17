// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The platform/toolkit coordinate system that drives every part of packaging. An hoppack.yaml section
// key like "macos-aarch64-appkit" or "linux-x86_64-gtk4" decodes into a `PlatformTriple`, and the
// current host is detected the same way so `hoppack` can pick a sensible default target.

/// A target operating system. Raw values match the first component of an hoppack.yaml section key.
public enum OS: String, Sendable, Hashable, CaseIterable {
    case macos, linux, windows
}

/// A target CPU architecture. Raw values match the middle component of an hoppack.yaml section key.
public enum Arch: String, Sendable, Hashable, CaseIterable {
    case aarch64, x86_64
}

/// A UI toolkit backend. Raw values match the last component of an hoppack.yaml section key.
public enum Toolkit: String, Sendable, Hashable, CaseIterable {
    case appkit, swiftui, gtk4, qt, winui

    /// The value the Skip/HopUI build plugin expects in the `HOP_TOOLKIT` environment variable. It mostly
    /// matches the raw value, except the section token `gtk4` maps to the build's `gtk`.
    public var hopToolkitEnvironmentValue: String {
        self == .gtk4 ? "gtk" : rawValue
    }
}

/// A fully-qualified packaging target: which OS, architecture, and toolkit an app is assembled for. Its
/// ``key`` is the canonical hoppack.yaml section name (e.g. `macos-aarch64-appkit`).
public struct PlatformTriple: Sendable, Hashable, CustomStringConvertible {
    public let os: OS
    public let arch: Arch
    public let toolkit: Toolkit

    public init(os: OS, arch: Arch, toolkit: Toolkit) {
        self.os = os
        self.arch = arch
        self.toolkit = toolkit
    }

    /// Parse a section key of the form `os-arch-toolkit`, e.g. `linux-aarch64-qt`. Returns nil if any
    /// component is unrecognized (so unrelated top-level YAML keys aren't mistaken for platform sections).
    public init?(_ key: String) {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let os = OS(rawValue: parts[0]),
              let arch = Arch(rawValue: parts[1]),
              let toolkit = Toolkit(rawValue: parts[2]) else { return nil }
        self.init(os: os, arch: arch, toolkit: toolkit)
    }

    /// The canonical hoppack.yaml section key for this triple.
    public var key: String { "\(os.rawValue)-\(arch.rawValue)-\(toolkit.rawValue)" }
    public var description: String { key }

    /// The OS this build of `hoppack` is running on. Packaging is performed natively (you build a macOS
    /// app on macOS, an MSIX on Windows, a flatpak on Linux), so the host OS is also the target OS.
    public static var hostOS: OS {
        #if os(macOS)
        return .macos
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #else
        return .linux
        #endif
    }

    /// The architecture this build of `hoppack` is running on.
    public static var hostArch: Arch {
        #if arch(arm64)
        return .aarch64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .x86_64
        #endif
    }
}

/// The build configuration passed through to `swift build`.
public enum BuildConfiguration: String, Sendable, Hashable, CaseIterable {
    case debug, release
    /// The value for `swift build -c <value>`.
    public var swiftBuildValue: String { rawValue }
}
