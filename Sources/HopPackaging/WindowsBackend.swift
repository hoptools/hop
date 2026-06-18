// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

// Windows backend: assembles an MSIX layout folder (the executable + assets + a generated AppxManifest.xml),
// launches the executable, and packages an `.msix` with the Windows SDK's `makeappx` tool.

public struct WindowsBackend: PlatformBackend {
    public init() {}
    public var os: OS { .windows }
    public var distributionFormat: String { "msix" }

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

        let installedExe = appDir.appending("\(meta.executable).exe")
        try FileOps.copy(executable, to: installedExe)
        if let staged = context.resourcesDirectory, FileOps.isDirectory(staged) {
            try FileOps.copyDirectoryContents(of: staged, into: appDir)
        }
        // Bundle the Swift runtime DLLs (swiftCore, Foundation, …) so the MSIX runs without a Swift install.
        if meta.properties["bundleSwiftRuntime"] == "true" {
            try await bundleSwiftRuntime(context, into: appDir)
        }
        // Bundle the app's DLLs (Windows App SDK / Qt) next to the .exe so the MSIX runs without prerequisites
        // (e.g. deploycommand: ["windeployqt", "{exe}"], or bundlelibraries pointing at the WinAppSDK runtime).
        try await context.bundleDependencies(executable: installedExe, app: appDir, libraryDirectory: appDir)
        // MSIX needs logo assets; stage the icon (if any) under assets\ where the manifest references it.
        if let icon = meta.icon {
            let ext = FilePath(icon).extension ?? "png"
            try FileOps.copy(context.packageDirectory.appending(icon), to: appDir.appending("assets/icon.\(ext)"))
        }
        try FileOps.write(appxManifest(for: meta, arch: context.target.arch), to: appDir.appending("AppxManifest.xml"))

        context.appArtifact = appDir
        context.logger.success("Assembled \(appDir.string)")
        return context
    }

    public func launch(_ context: PackagingContext) async throws {
        let appDir = try context.requireAppArtifact(stage: "launch")
        let exe = appDir.appending("\(context.metadata.executable).exe")
        context.logger.info("Launching \(context.metadata.title)…")
        try await context.runner.run(exe.string, context.metadata.launchArgs,
                                     workingDirectory: context.packageDirectory)
    }

    public func packageApp(_ context: PackagingContext) async throws -> PackagingContext {
        var context = context
        let appDir = try context.requireAppArtifact(stage: "package")
        let meta = context.metadata
        let msix = context.workDirectory.appending("\(meta.appslug)-\(context.target.key).msix")
        try FileOps.remove(msix)
        // makeappx ships with the Windows SDK; pass /o to overwrite. Signing/notarization are future stages.
        try await context.runner.run("makeappx", [
            "pack", "/d", appDir.string, "/p", msix.string, "/o",
        ], workingDirectory: context.workDirectory)
        context.packageArtifact = msix
        context.logger.success("Packaged \(msix.string)")
        return context
    }

    // MARK: - Helpers

    /// Copy the Swift runtime DLLs from the toolchain's bin (the directory containing swift.exe) next to the
    /// app, so the packaged executable launches without the Swift toolchain installed on the target machine.
    private func bundleSwiftRuntime(_ context: PackagingContext, into appDir: FilePath) async throws {
        let swiftPath = try await context.runner.capture("where", ["swift.exe"])
        let firstLine = swiftPath.split(whereSeparator: \.isNewline).first.map(String.init) ?? swiftPath
        guard !firstLine.isEmpty else {
            throw PackagingError.toolUnavailable(tool: "swift.exe", hint: "needed to locate the Swift runtime DLLs.")
        }
        let binDir = FilePath(firstLine).removingLastComponent()
        for entry in (try? FileOps.contents(of: binDir)) ?? [] where entry.lowercased().hasSuffix(".dll") {
            try FileOps.copy(binDir.appending(entry), to: appDir.appending(entry))
        }
        context.logger.detail("Bundled Swift runtime DLLs from \(binDir.string)")
    }

    private func appxManifest(for meta: ResolvedMetadata, arch: Arch) -> String {
        let processorArchitecture = arch == .aarch64 ? "arm64" : "x64"
        let publisher = meta.properties["publisher"] ?? "CN=\(meta.title)"
        let publisherDisplay = meta.properties["publisherDisplayName"] ?? meta.title
        let logo = meta.icon.map { "assets\\icon.\(FilePath($0).extension ?? "png")" } ?? "assets\\icon.png"
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
                 xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
                 xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
          <Identity Name="\(xmlEscape(meta.identifier))"
                    Publisher="\(xmlEscape(publisher))"
                    Version="\(msixVersion(meta.version, build: meta.build))"
                    ProcessorArchitecture="\(processorArchitecture)" />
          <Properties>
            <DisplayName>\(xmlEscape(meta.title))</DisplayName>
            <PublisherDisplayName>\(xmlEscape(publisherDisplay))</PublisherDisplayName>
            <Logo>\(logo)</Logo>
          </Properties>
          <Dependencies>
            <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.22621.0" />
          </Dependencies>
          <Resources>
            <Resource Language="en-us" />
          </Resources>
          <Capabilities>
            <rescap:Capability Name="runFullTrust" />
          </Capabilities>
          <Applications>
            <Application Id="App" Executable="\(xmlEscape(meta.executable)).exe" EntryPoint="Windows.FullTrustApplication">
              <uap:VisualElements DisplayName="\(xmlEscape(meta.title))" Description="\(xmlEscape(meta.title))"
                                  BackgroundColor="transparent" Square150x150Logo="\(logo)" Square44x44Logo="\(logo)" />
            </Application>
          </Applications>
        </Package>
        """
    }

    /// MSIX requires a 4-part Major.Minor.Build.Revision version; derive it from `version` (padded) + `build`.
    private func msixVersion(_ version: String, build: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        while parts.count < 3 { parts.append("0") }
        let revision = Int(build).map(String.init) ?? "0"
        return "\(parts[0]).\(parts[1]).\(parts[2]).\(revision)"
    }
}
