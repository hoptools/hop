// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

// Linux backend: assembles a self-contained app directory (FHS-style usr/bin + usr/share with a .desktop
// entry and icon), launches the binary directly, and packages a single-file `.flatpak` bundle via
// flatpak-builder (used for both the GTK4 and Qt toolkits).

public struct LinuxBackend: PlatformBackend {
    public init() {}
    public var os: OS { .linux }
    public var distributionFormat: String { "flatpak" }

    public func processResources(_ context: PackagingContext) async throws -> PackagingContext {
        var context = context
        let resources = context.workDirectory.appending("resources")
        try FileOps.recreateDirectory(resources)
        try FileOps.stageResources(context.metadata.resources, from: context.packageDirectory, into: resources)
        context.resourcesDirectory = resources
        context.logger.detail("Staged resources at \(resources.string)")
        return context
    }

    public func assembleApp(_ context: PackagingContext) async throws -> PackagingContext {
        var context = context
        let executable = try context.requireBuiltExecutable(stage: "AssembleApp")
        let meta = context.metadata
        let appDir = context.workDirectory.appending(meta.title)
        try FileOps.recreateDirectory(appDir)

        // FHS-style layout the flatpak module installs from.
        let binary = appDir.appending("usr/bin/\(meta.executable)")
        try FileOps.copy(executable, to: binary)
        try FileOps.makeExecutable(binary)

        // Make the app self-contained: bundle the Swift runtime (flatpak runtimes don't ship it) plus any
        // configured libraries into usr/lib (flatpak adds /app/lib to the loader path, where these land).
        let libDir = appDir.appending("usr/lib")
        if context.metadata.properties["bundleSwiftRuntime"] == "true" {
            try await bundleSwiftRuntime(context, into: libDir)
        }
        try await context.bundleDependencies(executable: binary, app: appDir, libraryDirectory: libDir)

        let desktop = appDir.appending("usr/share/applications/\(meta.identifier).desktop")
        try FileOps.write(desktopEntry(for: meta), to: desktop)

        if let icon = meta.icon {
            let ext = FilePath(icon).extension ?? "png"
            let installed = appDir.appending("usr/share/icons/hicolor/512x512/apps/\(meta.identifier).\(ext)")
            try FileOps.copy(context.packageDirectory.appending(icon), to: installed)
        }
        if let staged = context.resourcesDirectory, FileOps.isDirectory(staged) {
            try FileOps.copyDirectoryContents(of: staged, into: appDir.appending("usr/share/\(meta.executable)"))
        }

        context.appArtifact = appDir
        context.logger.success("Assembled \(appDir.string)")
        return context
    }

    public func launch(_ context: PackagingContext) async throws {
        let appDir = try context.requireAppArtifact(stage: "launch")
        let binary = appDir.appending("usr/bin/\(context.metadata.executable)")
        context.logger.info("Launching \(context.metadata.title)…")
        try await context.runner.run(binary.string, context.metadata.launchArgs,
                                     workingDirectory: context.packageDirectory)
    }

    public func packageApp(_ context: PackagingContext) async throws -> PackagingContext {
        var context = context
        let appDir = try context.requireAppArtifact(stage: "package")
        let meta = context.metadata

        let manifestPath = context.workDirectory.appending("\(meta.identifier).flatpak.json")
        try FileOps.write(try flatpakManifest(for: meta, toolkit: context.target.toolkit, appDir: appDir), to: manifestPath)

        let buildDir = context.workDirectory.appending("flatpak-build")
        let repoDir = context.workDirectory.appending("flatpak-repo")
        try FileOps.remove(buildDir)

        // Build the flatpak into a local OSTree repo, then export a single-file bundle. `--user` resolves the
        // runtime/SDK from the per-user installation (how CI installs them); `--install-deps-from=flathub`
        // pulls any missing runtime automatically.
        try await context.runner.run("flatpak-builder", [
            "--user", "--force-clean", "--disable-rofiles-fuse",
            "--install-deps-from=flathub",
            "--repo=\(repoDir.string)",
            buildDir.string, manifestPath.string,
        ], workingDirectory: context.workDirectory)

        let bundle = context.workDirectory.appending("\(meta.title)-\(meta.version).flatpak")
        try FileOps.remove(bundle)
        try await context.runner.run("flatpak", [
            "build-bundle", repoDir.string, bundle.string, meta.identifier,
        ], workingDirectory: context.workDirectory)

        context.packageArtifact = bundle
        context.logger.success("Packaged \(bundle.string)")
        return context
    }

    // MARK: - Helpers

    private func desktopEntry(for meta: ResolvedMetadata) -> String {
        var lines = [
            "[Desktop Entry]",
            "Type=Application",
            "Name=\(meta.title)",
            "Exec=\(meta.executable)\(meta.launchArgs.isEmpty ? "" : " " + meta.launchArgs.joined(separator: " "))",
            "Icon=\(meta.identifier)",
            "Terminal=false",
        ]
        if !meta.categories.isEmpty { lines.append("Categories=\(meta.categories.joined(separator: ";"));") }
        if let copyright = meta.copyright { lines.append("Comment=\(copyright)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func flatpakManifest(for meta: ResolvedMetadata, toolkit: Toolkit, appDir: FilePath) throws -> String {
        var buildCommands = [
            "install -Dm755 usr/bin/\(meta.executable) /app/bin/\(meta.executable)",
            "install -Dm644 usr/share/applications/\(meta.identifier).desktop /app/share/applications/\(meta.identifier).desktop",
        ]
        if let icon = meta.icon {
            let ext = FilePath(icon).extension ?? "png"
            let rel = "usr/share/icons/hicolor/512x512/apps/\(meta.identifier).\(ext)"
            buildCommands.append("install -Dm644 \(rel) /app/share/icons/hicolor/512x512/apps/\(meta.identifier).\(ext)")
        }
        // Stage bundled libraries (Swift runtime + deps) into /app/lib, which is on the loader path.
        if FileOps.isDirectory(appDir.appending("usr/lib")) {
            buildCommands.append("mkdir -p /app/lib")
            buildCommands.append("cp -a usr/lib/. /app/lib/")
        }
        let runtime = meta.properties["flatpakRuntime"] ?? defaultRuntime(for: toolkit)
        let manifest: [String: Any] = [
            "app-id": meta.identifier,
            "runtime": runtime,
            "runtime-version": meta.properties["flatpakRuntimeVersion"] ?? defaultRuntimeVersion(for: runtime),
            "sdk": meta.properties["flatpakSdk"] ?? defaultSdk(for: runtime),
            "command": meta.executable,
            "finish-args": ["--socket=fallback-x11", "--socket=wayland", "--share=ipc", "--device=dri"],
            "modules": [[
                "name": meta.executable,
                "buildsystem": "simple",
                "build-commands": buildCommands,
                "sources": [["type": "dir", "path": appDir.string]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Default flatpak runtime per toolkit: GNOME ships GTK4, KDE ships Qt6; freedesktop otherwise.
    private func defaultRuntime(for toolkit: Toolkit) -> String {
        switch toolkit {
        case .gtk4: return "org.gnome.Platform"
        case .qt: return "org.kde.Platform"
        default: return "org.freedesktop.Platform"
        }
    }
    private func defaultRuntimeVersion(for runtime: String) -> String {
        if runtime.contains("gnome") { return "46" }
        if runtime.contains("kde") { return "6.7" }
        return "23.08"
    }
    private func defaultSdk(for runtime: String) -> String {
        if runtime.contains("gnome") { return "org.gnome.Sdk" }
        if runtime.contains("kde") { return "org.kde.Sdk" }
        return "org.freedesktop.Sdk"
    }

    /// Copy the Swift runtime shared libraries (libswiftCore, Foundation, Dispatch, ICU, …) from the active
    /// toolchain into the app's lib dir so the binary runs inside the flatpak sandbox without a Swift install.
    private func bundleSwiftRuntime(_ context: PackagingContext, into libDir: FilePath) async throws {
        let swiftcPath = try await context.runner.capture("which", ["swiftc"])
        guard !swiftcPath.isEmpty else {
            throw PackagingError.toolUnavailable(tool: "swiftc", hint: "needed to locate the Swift runtime for bundling.")
        }
        let resolved = try await context.runner.capture("readlink", ["-f", swiftcPath])
        // <toolchain>/usr/bin/swiftc → <toolchain>/usr/lib/swift/linux
        let runtimeDir = FilePath(resolved).removingLastComponent().removingLastComponent().appending("lib/swift/linux")
        guard FileOps.isDirectory(runtimeDir) else {
            throw PackagingError.toolUnavailable(tool: "Swift runtime", hint: "not found at \(runtimeDir.string).")
        }
        try FileOps.ensureDirectory(libDir)
        for entry in (try? FileOps.contents(of: runtimeDir)) ?? [] where entry.contains(".so") {
            try FileOps.copy(runtimeDir.appending(entry), to: libDir.appending(entry))
        }
        context.logger.detail("Bundled Swift runtime from \(runtimeDir.string)")
    }
}
