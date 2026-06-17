// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The shared app entry point. The SAME scene graph compiles against either HopUI or Apple's SwiftUI
// (selected by the per-executable HOPUI_TOOLKIT_* define in Package.swift). It declares a primary
// WindowGroup plus an "About" Window opened on demand via @Environment(\.openWindow) — identical
// SwiftUI source on all four toolkits.
//
// On the native SwiftUI build this struct is the @main entry point. The three HopUI executables
// leave @main off (each has its own main.swift that picks a toolkit and calls runApp).
#if HOPUI_TOOLKIT_SWIFTUI
import SwiftUI
import AppKit  // NSApplication activation policy: promote the bare SwiftPM executable to a real foreground app
#else
import HopUI
#endif
import Foundation  // ProcessInfo (HOP_WINDOW_SIZE)

#if HOPUI_TOOLKIT_SWIFTUI
/// Without an `.app` bundle, a `swift run` SwiftUI executable launches as a background process: no menu
/// bar, no key-window focus, no keyboard events. Forcing `.regular` activation policy (and activating)
/// at launch makes it a normal foreground app — SwiftUI then installs its standard menu bar and routes
/// key events. This mirrors what HopUI's AppKit `runApp` does (setActivationPolicy(.regular) + activate).
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

#if HOPUI_TOOLKIT_SWIFTUI
/// The native SwiftUI window's initial size, honoring HOP_WINDOW_SIZE (uniform screenshot size); 820×760
/// otherwise. Mirrors the HopUI backends' `hopRequestedWindowSize()` so every toolkit opens the same size.
private var demoWindowSize: CGSize {
    if let raw = ProcessInfo.processInfo.environment["HOP_WINDOW_SIZE"] {
        let p = raw.lowercased().split(separator: "x")
        if p.count == 2, let w = Double(p[0]), let h = Double(p[1]), w > 0, h > 0 { return CGSize(width: w, height: h) }
    }
    return CGSize(width: 820, height: 760)
}
#endif

#if HOPUI_TOOLKIT_SWIFTUI
@main
#endif
struct HopDemoApp: App {
    #if HOPUI_TOOLKIT_SWIFTUI
    // Promotes the un-bundled executable to a foreground app (menu bar + keyboard focus) at launch.
    @NSApplicationDelegateAdaptor(DemoAppDelegate.self) private var appDelegate
    #endif

    // The app owns the shared model (so both ContentView and the Appearance menu command can reach it)
    // and injects it into the scene's environment.
    private let model = DemoModel()

    var body: some Scene {
        WindowGroup("HopUI · \(hopuiToolkitName)") {
            ContentView()
                .environment(model)
        }
        #if HOPUI_TOOLKIT_SWIFTUI
        .defaultSize(width: demoWindowSize.width, height: demoWindowSize.height)
        #endif
        .commands {
            CommandMenu("Appearance") {
                Button("Toggle Light / Dark") { model.toggleColorScheme() }
            }
        }
        Window("About HopUI", id: "about") {
            AboutView()
        }
    }
}

/// Content of the secondary "About" window, opened from the toolbar's About button. Plain shared
/// SwiftUI (VStack + Text) so it renders identically on every toolkit.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("HopUI")
            Text("A native-Swift, multi-toolkit SwiftUI implementation for the desktop.")
            Text("Running on the \(hopuiToolkitName) toolkit.")
        }
    }
}
