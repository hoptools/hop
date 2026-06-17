// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

// Shared dependency-bundling used by the backends so an assembled app is self-contained and launches with
// no prerequisite install: run the configured `deployCommand` (e.g. windeployqt) and copy `bundleLibraries`
// (e.g. the Windows App SDK DLLs) into the app's platform-specific library location. Toolkit specifics stay
// in hoppack.yaml; the backend only supplies where libraries go.

extension PackagingContext {
    /// Apply `deployCommand` + `bundleLibraries` for this target.
    /// - Parameters:
    ///   - executable: the built executable (substituted for `{exe}`).
    ///   - app: the assembled app directory (substituted for `{app}`; the deploy command's working directory).
    ///   - libraryDirectory: where `bundleLibraries` entries are copied (created on demand).
    func bundleDependencies(executable: FilePath, app: FilePath, libraryDirectory: FilePath) async throws {
        if !metadata.deployCommand.isEmpty {
            let argv = metadata.deployCommand.map {
                $0.replacingOccurrences(of: "{exe}", with: executable.string)
                  .replacingOccurrences(of: "{app}", with: app.string)
            }
            logger.detail("Deploying dependencies: \(argv.joined(separator: " "))")
            try await runner.run(argv[0], Array(argv.dropFirst()), workingDirectory: app)
        }
        guard !metadata.bundleLibraries.isEmpty else { return }
        try FileOps.ensureDirectory(libraryDirectory)
        for entry in metadata.bundleLibraries {
            let source = packageDirectory.appending(entry)
            guard FileOps.exists(source) else {
                logger.warn("bundlelibraries entry not found, skipping: \(entry)")
                continue
            }
            // A directory contributes its contents; a single file is copied as-is.
            if FileOps.isDirectory(source) {
                try FileOps.copyDirectoryContents(of: source, into: libraryDirectory)
            } else {
                try FileOps.copy(source, to: libraryDirectory.appending(source.lastComponent?.string ?? entry))
            }
        }
        logger.detail("Bundled libraries into \(libraryDirectory.string)")
    }
}
