// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The application metadata an hoppack.yaml provides — both the top-level common `metadata:` object and
// each platform section's overrides. `Metadata` is the raw, all-optional decoded form; `ResolvedMetadata`
// is the merged, defaulted form a packaging pipeline actually consumes.

/// Raw application metadata decoded from an hoppack.yaml `metadata:` block or a platform section. Every
/// field is optional so a platform section can override just the keys that differ from the common block.
public struct Metadata: Sendable, Equatable, Decodable {
    /// Human-readable application name (macOS CFBundleName, Linux .desktop Name, MSIX DisplayName).
    public var title: String?
    /// Reverse-DNS application identifier (macOS CFBundleIdentifier, flatpak app-id, MSIX Identity name).
    public var identifier: String?
    /// A short, lowercase slug used to name the generated distribution file (`<appslug>-<triple>.<ext>`).
    public var appslug: String?
    /// Marketing version string, e.g. "1.2.0".
    public var version: String?
    /// Build number, e.g. "42".
    public var build: String?
    /// The SwiftPM executable product to build and bundle (e.g. `hop-demo-appkit`).
    public var executable: String?
    /// Arguments passed to the app when launched via `hoppack run`.
    public var launchArgs: [String]?
    /// Path (relative to the package) to an application icon.
    public var icon: String?
    /// Platform application categories (macOS LSApplicationCategoryType, Linux .desktop Categories).
    public var categories: [String]?
    /// Copyright / legal line.
    public var copyright: String?
    /// Minimum OS version (macOS LSMinimumSystemVersion, MSIX MinVersion).
    public var minimumOSVersion: String?
    /// Additional files/directories (relative to the package) to copy into the app's resources.
    public var resources: [String]?
    /// A dependency-deployment command (argv) run while assembling the app, so the package is self-contained
    /// and launches without prerequisites. `{exe}` and `{app}` are substituted with the built executable and
    /// the assembled app directory (e.g. `["windeployqt", "{exe}"]` to stage Qt's DLLs next to the binary).
    public var deployCommand: [String]?
    /// Library files/directories (relative to the package) to bundle into the app's library location
    /// (macOS Contents/Frameworks, Linux usr/lib, Windows next to the .exe) — e.g. Windows App SDK DLLs.
    public var bundleLibraries: [String]?
    /// Free-form extension bag: forward-compatible keys consumed by future stages (signing, etc.) and by
    /// backends (e.g. `flatpakRuntime`, `bundleSwiftRuntime`, `publisher`).
    public var properties: [String: String]?

    enum CodingKeys: String, CodingKey {
        case title, identifier, appslug, version, build, executable
        case launchArgs = "launchargs"
        case icon, categories, copyright
        case minimumOSVersion = "minosversion"
        case resources
        case deployCommand = "deploycommand"
        case bundleLibraries = "bundlelibraries"
        case properties
    }

    public init() {}

    /// Produce a copy of `base` with this metadata's non-nil fields layered on top — the fallback rule the
    /// spec calls for: a platform section overrides the top-level common `metadata:` key by key. `properties`
    /// merge entry-by-entry (this side wins on conflict).
    public func merged(over base: Metadata) -> Metadata {
        var r = base
        if let title { r.title = title }
        if let identifier { r.identifier = identifier }
        if let appslug { r.appslug = appslug }
        if let version { r.version = version }
        if let build { r.build = build }
        if let executable { r.executable = executable }
        if let launchArgs { r.launchArgs = launchArgs }
        if let icon { r.icon = icon }
        if let categories { r.categories = categories }
        if let copyright { r.copyright = copyright }
        if let minimumOSVersion { r.minimumOSVersion = minimumOSVersion }
        if let resources { r.resources = resources }
        if let deployCommand { r.deployCommand = deployCommand }
        if let bundleLibraries { r.bundleLibraries = bundleLibraries }
        if let properties {
            r.properties = (base.properties ?? [:]).merging(properties) { _, new in new }
        }
        return r
    }
}

/// Merged, defaulted metadata ready for packaging. Fields that packaging always needs are non-optional
/// (defaulted from the triple / package name when the YAML omits them); the rest stay optional.
public struct ResolvedMetadata: Sendable, Equatable {
    public let title: String
    public let identifier: String
    /// Lowercase slug for naming the distribution file (`<appslug>-<triple>.<ext>`).
    public let appslug: String
    public let version: String
    public let build: String
    public let executable: String
    public let launchArgs: [String]
    public let icon: String?
    public let categories: [String]
    public let copyright: String?
    public let minimumOSVersion: String?
    public let resources: [String]
    public let deployCommand: [String]
    public let bundleLibraries: [String]
    public let properties: [String: String]

    /// Resolve raw metadata into a complete set, applying defaults. Throws if the required `executable`
    /// (the SwiftPM product to build) is absent from both the platform section and the common block.
    public init(_ m: Metadata, triple: PlatformTriple, packageName: String) throws {
        guard let executable = m.executable else {
            throw PackagingError.missingMetadata(key: "executable", target: triple)
        }
        let title = m.title ?? packageName
        self.title = title
        self.executable = executable
        let slug = title.filter { $0.isLetter || $0.isNumber }
        self.identifier = m.identifier ?? "com.example.\(slug.isEmpty ? "app" : slug)"
        // Default the slug from the title (lowercased, alphanumerics only) when not specified.
        let lowerSlug = title.lowercased().filter { $0.isLetter || $0.isNumber }
        self.appslug = m.appslug ?? (lowerSlug.isEmpty ? "app" : lowerSlug)
        self.version = m.version ?? "1.0.0"
        self.build = m.build ?? "1"
        self.launchArgs = m.launchArgs ?? []
        self.icon = m.icon
        self.categories = m.categories ?? []
        self.copyright = m.copyright
        self.minimumOSVersion = m.minimumOSVersion
        self.resources = m.resources ?? []
        self.deployCommand = m.deployCommand ?? []
        self.bundleLibraries = m.bundleLibraries ?? []
        self.properties = m.properties ?? [:]
    }
}
