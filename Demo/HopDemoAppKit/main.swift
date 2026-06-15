// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(AppKit)
import HopUI
import HopAppKit

runApp(HopDemoApp(), backend: AppKitBackend())
#else
print("The AppKit demo requires macOS.")
#endif
