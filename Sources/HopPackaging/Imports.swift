// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// HopPackaging uses the same `FilePath` type as swift-subprocess so paths flow into `Subprocess.run`'s
// `workingDirectory` without conversion. swift-subprocess (and we) use the SDK's `System` on Apple
// platforms and the swift-system package's `SystemPackage` elsewhere. Re-exporting module-wide keeps
// `FilePath` consistent across every file here and in clients of HopPackaging (e.g. the `hoppack` CLI).
#if canImport(System)
@_exported import System
#else
@_exported import SystemPackage
#endif
