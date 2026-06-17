// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

// Tests for the open component system: that a built-in migrated onto it (Image, Picker) behaves
// correctly, that style-driven implementation variance recreates the native widget while preserving
// state, and that a decoupled, self-hosting component (the third-party extension case) renders with no
// backend renderer registered. See the toolkit-extensibility plan + `Component.swift`.

// A Picker whose style and selection are driven by @State, so tests can flip both.
@MainActor private struct StyledPickerView: View {
    @State var style: PickerStyle = .menu
    @State var choice = 1
    var body: some View {
        VStack {
            Button("toSegmented") { style = .segmented }
            Button("toRadio") { style = .radioGroup }
            Button("pick2") { choice = 2 }
            Picker("Number", selection: $choice) {
                Text("One").tag(1)
                Text("Two").tag(2)
                Text("Three").tag(3)
            }
            .pickerStyle(style)
        }
    }
}

// A self-hosting component (the third-party case): it carries its own native code via `makeNative` and
// is NOT registered in any backend's renderer registry.
private struct SelfHostedComponent: WidgetComponent {
    var widgetKey: WidgetKey { WidgetKey("test.selfhosted") }
    var role: WidgetRole { .leaf }
    func makeNative(_ toolkit: ToolkitID) -> Any? {
        let widget = MockWidget(kind: .label)   // the mock's "raw native widget"
        widget.text = "self-hosted!"
        return widget
    }
}

@MainActor private struct SelfHostedView: View, PrimitiveView {
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        RenderNode(id: context.id, component: SelfHostedComponent())
    }
}

@MainActor @Suite struct ComponentSystemTests {
    private func button(_ toolkit: MockToolkit, _ title: String) -> MockWidget? {
        toolkit.widgets.first { $0.kind == .button && $0.title == title }
    }
    private func tap(_ toolkit: MockToolkit, _ title: String) throws {
        try #require(button(toolkit, title)).action?()
        toolkit.drainMainThread()
    }
    private func picker(_ toolkit: MockToolkit) -> MockWidget? {
        toolkit.widgets.last { $0.kind == .picker }   // newest, after any recreate
    }

    // MARK: built-in via the component path

    @Test func testImageRendersViaComponentRegistry() throws {
        let toolkit = MockToolkit()
        runHopApp(Image(systemName: "star").frame(width: 20, height: 20), toolkit: toolkit, title: "t")
        let image = try #require(toolkit.widgets.first { $0.kind == .image })
        #expect(image.imageSpec != nil)   // realized + configured through the registered image renderer
    }

    // MARK: style-driven implementation variance (the Picker pilot's whole point)

    @Test func testPickerStyleChangeRecreatesTheNativeWidget() throws {
        let toolkit = MockToolkit()
        runHopApp(StyledPickerView(), toolkit: toolkit, title: "t")
        #expect(picker(toolkit)?.pickerStyleName == "menu")   // default style

        toolkit.clearOps()
        try tap(toolkit, "toSegmented")
        // Different widgetKey ("picker.menu" → "picker.segmented") ⇒ tear down + recreate, not reconfigure.
        #expect(toolkit.ops.contains("make:picker.segmented"))
        #expect(toolkit.removeCount >= 1)
        #expect(picker(toolkit)?.pickerStyleName == "segmented")

        // radioGroup is a different layout role (.native) as well as a different widget — still just works.
        toolkit.clearOps()
        try tap(toolkit, "toRadio")
        #expect(toolkit.ops.contains("make:picker.radioGroup"))
        #expect(picker(toolkit)?.pickerStyleName == "radioGroup")
    }

    @Test func testSelectionSurvivesAStyleChange() throws {
        let toolkit = MockToolkit()
        runHopApp(StyledPickerView(), toolkit: toolkit, title: "t")
        try tap(toolkit, "pick2")                              // choice = 2 → selectedIndex 1 (Two)
        #expect(picker(toolkit)?.picker?.selectedIndex == 1)

        try tap(toolkit, "toSegmented")                        // recreate as a different widget
        #expect(picker(toolkit)?.pickerStyleName == "segmented")
        #expect(picker(toolkit)?.picker?.selectedIndex == 1)   // selection (in @State) re-applied to the new widget
    }

    @Test func testSelectionChangeDoesNotRecreateThePicker() throws {
        let toolkit = MockToolkit()
        runHopApp(StyledPickerView(), toolkit: toolkit, title: "t")
        toolkit.clearOps()
        try tap(toolkit, "pick2")                              // only the selection changes; style stays .menu
        #expect(!toolkit.ops.contains { $0.hasPrefix("make:picker") })   // same widgetKey → updated in place
        #expect(picker(toolkit)?.picker?.selectedIndex == 1)
    }

    // MARK: decoupled, self-hosting component (third-party extension case)

    @Test func testSelfHostedComponentRendersWithoutARegisteredRenderer() throws {
        let toolkit = MockToolkit()
        runHopApp(SelfHostedView(), toolkit: toolkit, title: "t")
        // No renderer is registered for "test.selfhosted"; it rendered via the component's own makeNative.
        #expect(toolkit.ops.contains("make:selfhosted"))
        #expect(toolkit.liveLabels().contains("self-hosted!"))
    }
}
