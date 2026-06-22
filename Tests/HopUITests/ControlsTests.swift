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
        let toolkit = MockToolkit()
        runHopApp(ToggleHost(), toolkit: toolkit, title: "test")
        // A default Toggle (no .toggleStyle) is the `.automatic` style.
        let toggle = try #require(toolkit.widgets.first { $0.kind == .toggle(.automatic) })
        #expect(toggle.boolValue == false)
        #expect(toolkit.liveLabels().contains("Wi-Fi"))  // the composed label

        toolkit.clearOps()
        toggle.onChangeBool?(true)            // simulate the user flipping the switch
        toolkit.drainMainThread()
        #expect(try #require(toolkit.widgets.first { $0.kind == .toggle(.automatic) }).boolValue == true)
        #expect(toolkit.makeCount == 0)       // reconfigured, not rebuilt
    }

    @Test func testSecureFieldIsMaskedKindAndBinds() throws {
        let toolkit = MockToolkit()
        runHopApp(SecureHost(), toolkit: toolkit, title: "test")
        let field = try #require(toolkit.widgets.first { $0.kind == .secureField })
        #expect(field.kind == .secureField)   // a distinct kind from .textField

        field.onChange?("hunter2")
        toolkit.drainMainThread()
        #expect(try #require(toolkit.widgets.first { $0.kind == .secureField }).value == "hunter2")
    }

    @Test func testStepperIncrementsAndClampsToRange() throws {
        let toolkit = MockToolkit()
        runHopApp(StepperHost(), toolkit: toolkit, title: "test")
        func button(_ title: String) -> MockWidget? {
            toolkit.widgets.first { $0.kind == .button && $0.title == title }
        }
        #expect(toolkit.liveLabels().contains("Count: 5"))

        try #require(button("+")).action?()
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("Count: 6"))

        // Decrement past nothing special, then drive to the upper bound and confirm it clamps at 10.
        for _ in 0 ..< 8 { try #require(button("+")).action?(); toolkit.drainMainThread() }
        #expect(toolkit.liveLabels().contains("Count: 10"))
        try #require(button("+")).action?()
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("Count: 10"))  // clamped, not 11
    }

    @Test func testLabelComposesIconAndTitle() {
        let toolkit = MockToolkit()
        runHopApp(Label("Files", systemImage: "folder"), toolkit: toolkit, title: "test")
        #expect(toolkit.widgets.contains { $0.kind == .image })   // the leading icon
        #expect(toolkit.liveLabels().contains("Files"))           // the title
    }

    @Test func testLinkRendersAsTitledButton() {
        let toolkit = MockToolkit()
        runHopApp(Link("Hop", destination: URL(string: "https://github.com/hoptools/hop")!), toolkit: toolkit, title: "test")
        #expect(toolkit.widgets.contains { $0.kind == .button && $0.title == "Hop" })
    }
}
