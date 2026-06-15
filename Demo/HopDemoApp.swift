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
#else
import HopUI
#endif

#if HOPUI_TOOLKIT_SWIFTUI
@main
#endif
struct HopDemoApp: App {
    // The app owns the shared model (so both ContentView and the Appearance menu command can reach it)
    // and injects it into the scene's environment.
    private let model = DemoModel()

    var body: some Scene {
        WindowGroup("HopUI · \(hopuiToolkitName)") {
            ContentView()
                .environment(model)
        }
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
