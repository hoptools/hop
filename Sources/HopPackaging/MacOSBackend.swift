// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

// macOS backend: assembles a proper `.app` bundle (Contents/MacOS + Resources + Info.plist), launches it
// via LaunchServices (`open`), and packages it into a compressed `.dmg` with `hdiutil`.

public struct MacOSBackend: PlatformBackend {
    public init() {}
    public var os: OS { .macos }
    public var distributionFormat: String { "dmg" }

    public func processResources(_ context: PackagingContext) async throws -> PackagingContext {
        var context = context
        let resources = context.workDirectory.appending("resources")
        try FileOps.recreateDirectory(resources)
        try FileOps.stageResources(context.metadata.resources, from: context.packageDirectory, into: resources)
        if let icon = context.metadata.icon {
            try FileOps.stageResources([icon], from: context.packageDirectory, into: resources)
        }
        context.resourcesDirectory = resources
        context.logger.detail("Staged resources at \(resources.string)")
        return context
    }

    public func assembleApp(_ context: PackagingContext) async throws -> PackagingContext {
        var context = context
        let executable = try context.requireBuiltExecutable(stage: "AssembleApp")
        let app = context.workDirectory.appending("\(context.metadata.title).app")
        let contents = app.appending("Contents")
        let macOS = contents.appending("MacOS")
        let resources = contents.appending("Resources")

        try FileOps.recreateDirectory(app)
        try FileOps.ensureDirectory(macOS)
        try FileOps.ensureDirectory(resources)

        // The executable inside the bundle keeps the product name (CFBundleExecutable references it).
        let installedBinary = macOS.appending(context.metadata.executable)
        try FileOps.copy(executable, to: installedBinary)
        try FileOps.makeExecutable(installedBinary)

        if let staged = context.resourcesDirectory, FileOps.isDirectory(staged) {
            try FileOps.copyDirectoryContents(of: staged, into: resources)
        }
        // Bundle any extra dynamic libraries into Contents/Frameworks so the .app is self-contained.
        try await context.bundleDependencies(executable: installedBinary, app: app,
                                             libraryDirectory: contents.appending("Frameworks"))
        try FileOps.write(infoPlist(for: context.metadata), to: contents.appending("Info.plist"))

        context.appArtifact = app
        context.logger.success("Assembled \(app.string)")
        return context
    }

    public func launch(_ context: PackagingContext) async throws {
        let app = try context.requireAppArtifact(stage: "launch")
        // `open -W` blocks until the app exits; `--args` forwards launch arguments to the app.
        var args = ["-W", app.string]
        if !context.metadata.launchArgs.isEmpty { args += ["--args"] + context.metadata.launchArgs }
        context.logger.info("Launching \(context.metadata.title)…")
        try await context.runner.run("open", args)
    }

    public func packageApp(_ context: PackagingContext) async throws -> PackagingContext {
        var context = context
        let app = try context.requireAppArtifact(stage: "package")
        let dmg = context.workDirectory.appending("\(context.metadata.appslug)-\(context.target.key).dmg")
        try FileOps.remove(dmg)
        try await context.runner.run("hdiutil", [
            "create",
            "-volname", context.metadata.title,
            "-srcfolder", app.string,
            "-ov", "-format", "UDZO",
            dmg.string,
        ])
        context.packageArtifact = dmg
        context.logger.success("Packaged \(dmg.string)")
        return context
    }

    // MARK: - Helpers

    private func infoPlist(for metadata: ResolvedMetadata) -> String {
        var keys: [(String, String)] = [
            ("CFBundleName", metadata.title),
            ("CFBundleDisplayName", metadata.title),
            ("CFBundleIdentifier", metadata.identifier),
            ("CFBundleExecutable", metadata.executable),
            ("CFBundleShortVersionString", metadata.version),
            ("CFBundleVersion", metadata.build),
            ("CFBundlePackageType", "APPL"),
            ("CFBundleInfoDictionaryVersion", "6.0"),
            ("NSPrincipalClass", "NSApplication"),
            ("NSHighResolutionCapable", "true"),
        ]
        if let minimum = metadata.minimumOSVersion { keys.append(("LSMinimumSystemVersion", minimum)) }
        if let iconPath = metadata.icon {
            let iconFile = FilePath(iconPath).lastComponent?.string ?? iconPath
            keys.append(("CFBundleIconFile", iconFile))
        }
        if let category = metadata.categories.first { keys.append(("LSApplicationCategoryType", category)) }
        if let copyright = metadata.copyright { keys.append(("NSHumanReadableCopyright", copyright)) }

        let body = keys.map { key, value in
            // NSHighResolutionCapable is the lone boolean; everything else is a string.
            if key == "NSHighResolutionCapable" {
                return "    <key>\(key)</key>\n    <\(value == "true" ? "true" : "false")/>"
            }
            return "    <key>\(key)</key>\n    <string>\(xmlEscape(value))</string>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)
        </dict>
        </plist>
        """
    }
}

func xmlEscape(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
