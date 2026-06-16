// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import WinUI
import WinAppSDK
import HopUI
import HopWinUI

// The WinUI 3 entry point. Unlike the GTK4/Qt/AppKit demos — whose `main.swift` calls `runApp` directly
// and lets the toolkit's blocking `run` own the loop — a Windows App SDK app must enter through a
// `SwiftApplication` subclass. `SwiftApplication.main()` initializes the Windows App Runtime, starts the
// XAML `Application`, and invokes `onLaunched` on the UI thread; that is where HopUI is booted. The
// `WinUIToolkit` then creates the XAML `Window` and returns immediately — the Win32/XAML message loop is
// owned by `Application.start`, which is already running and keeps pumping after `onLaunched` returns.
//
// (This file is intentionally NOT named `main.swift`: a `main.swift` implies top-level code as the entry
// point, which conflicts with the `@main` attribute below.)
@main
final class HopWinUIDemoApp: SwiftApplication {
    // `SwiftApplication`'s `init()`/`onLaunched` are nonisolated (the Windows App SDK calls them through
    // WinRT), so the overrides must match — this demo target otherwise defaults every declaration to
    // `MainActor`. `onLaunched` runs on the XAML UI thread (the main thread), so we assume main-actor
    // isolation to boot HopUI (whose `runApp` and the toolkit are `@MainActor`).
    nonisolated required init() { super.init() }

    nonisolated override func onLaunched(_ args: LaunchActivatedEventArgs) {
        MainActor.assumeIsolated {
            runApp(HopDemoApp(), toolkit: WinUIToolkit())
        }
    }
}
