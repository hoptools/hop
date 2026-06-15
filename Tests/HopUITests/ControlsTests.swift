// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import HopUI

@MainActor private struct ToggleHost: View {
    @State var on = false
    var body: some View { Toggle("Wi-Fi", isOn: $on) }
}

@MainActor private struct SecureHost: View {
    @State var pw = ""
    var body: some View { SecureField("Password", text: $pw) }
}

@MainActor private struct StepperHost: View {
    @State var n = 5
    var body: some View {
        VStack {
            Text("Count: \(n)")
            Stepper("Count", value: $n, in: 0 ... 10)
        }
    }
}

@MainActor @Suite struct ControlsTests {
    @Test func testToggleBindsAndReflectsState() throws {
        let backend = MockBackend()
        runHopApp(ToggleHost(), backend: backend, title: "test")
        let toggle = try #require(backend.widgets.first { $0.kind == .toggle })
        #expect(toggle.boolValue == false)
        #expect(backend.liveLabels().contains("Wi-Fi"))  // the composed label

        backend.clearOps()
        toggle.onChangeBool?(true)            // simulate the user flipping the switch
        backend.drainMainThread()
        #expect(try #require(backend.widgets.first { $0.kind == .toggle }).boolValue == true)
        #expect(backend.makeCount == 0)       // reconfigured, not rebuilt
    }

    @Test func testSecureFieldIsMaskedKindAndBinds() throws {
        let backend = MockBackend()
        runHopApp(SecureHost(), backend: backend, title: "test")
        let field = try #require(backend.widgets.first { $0.kind == .secureField })
        #expect(field.kind == .secureField)   // a distinct kind from .textField

        field.onChange?("hunter2")
        backend.drainMainThread()
        #expect(try #require(backend.widgets.first { $0.kind == .secureField }).value == "hunter2")
    }

    @Test func testStepperIncrementsAndClampsToRange() throws {
        let backend = MockBackend()
        runHopApp(StepperHost(), backend: backend, title: "test")
        func button(_ title: String) -> MockWidget? {
            backend.widgets.first { $0.kind == .button && $0.title == title }
        }
        #expect(backend.liveLabels().contains("Count: 5"))

        try #require(button("+")).action?()
        backend.drainMainThread()
        #expect(backend.liveLabels().contains("Count: 6"))

        // Decrement past nothing special, then drive to the upper bound and confirm it clamps at 10.
        for _ in 0 ..< 8 { try #require(button("+")).action?(); backend.drainMainThread() }
        #expect(backend.liveLabels().contains("Count: 10"))
        try #require(button("+")).action?()
        backend.drainMainThread()
        #expect(backend.liveLabels().contains("Count: 10"))  // clamped, not 11
    }

    @Test func testLabelComposesIconAndTitle() {
        let backend = MockBackend()
        runHopApp(Label("Files", systemImage: "folder"), backend: backend, title: "test")
        #expect(backend.widgets.contains { $0.kind == .image })   // the leading icon
        #expect(backend.liveLabels().contains("Files"))           // the title
    }

    @Test func testLinkRendersAsTitledButton() {
        let backend = MockBackend()
        runHopApp(Link("Hop", destination: URL(string: "https://github.com/hoptools/hop")!), backend: backend, title: "test")
        #expect(backend.widgets.contains { $0.kind == .button && $0.title == "Hop" })
    }
}
