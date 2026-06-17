// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

@MainActor private struct ColorPickerHost: View {
    @State var color: Color
    let supportsOpacity: Bool
    init(color: Color, supportsOpacity: Bool = true) {
        _color = State(wrappedValue: color)
        self.supportsOpacity = supportsOpacity
    }
    var body: some View { ColorPicker("Tint", selection: $color, supportsOpacity: supportsOpacity) }
}

@MainActor @Suite struct ColorPickerTests {
    @Test func testRendersLabeledLeafCarryingSpec() throws {
        let toolkit = MockToolkit()
        runHopApp(ColorPickerHost(color: Color(red: 0.1, green: 0.2, blue: 0.3, opacity: 1)),
                  toolkit: toolkit, title: "test")
        #expect(toolkit.liveLabels().contains("Tint"))   // composed leading label
        let spec = try #require(toolkit.widgets.first { $0.kind == "colorPicker" }?.colorPicker)
        #expect(spec.supportsOpacity == true)
        #expect(spec.color.red == 0.1)
        #expect(spec.color.blue == 0.3)
    }

    @Test func testChangeWritesBackToBinding() throws {
        let toolkit = MockToolkit()
        runHopApp(ColorPickerHost(color: .black), toolkit: toolkit, title: "test")
        let widget = try #require(toolkit.widgets.first { $0.kind == "colorPicker" })
        toolkit.clearOps()
        widget.colorPicker?.onChange(Color(red: 0.25, green: 0.5, blue: 0.75, opacity: 0.5))
        toolkit.drainMainThread()
        let spec = try #require(toolkit.widgets.first { $0.kind == "colorPicker" }?.colorPicker)
        #expect(spec.color.red == 0.25)
        #expect(spec.color.green == 0.5)
        #expect(spec.color.blue == 0.75)
        #expect(spec.color.opacity == 0.5)
        #expect(toolkit.makeCount == 0)   // reconfigured in place, not rebuilt
    }

    @Test func testSupportsOpacityFlows() throws {
        let toolkit = MockToolkit()
        runHopApp(ColorPickerHost(color: .red, supportsOpacity: false), toolkit: toolkit, title: "test")
        let spec = try #require(toolkit.widgets.first { $0.kind == "colorPicker" }?.colorPicker)
        #expect(spec.supportsOpacity == false)
    }
}
