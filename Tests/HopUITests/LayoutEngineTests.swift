// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

// Drives the LayoutEngine directly with stub closures (no toolkit), so layout behavior that depends on
// native-allocated sizes — chiefly split-view panes — can be tested deterministically. The split itself
// stays native: the toolkit positions the panes; HopUI lays out the CONTENT inside each pane's size.
@MainActor @Suite struct LayoutEngineTests {
    /// A label's intrinsic size, matching the MockToolkit's measure: `text.count * 8 + 8` wide, 20 tall.
    private static func measure(_ node: RenderNode, _ proposal: ProposedViewSize) -> CGSize {
        if node.component.widgetKey.rawValue == "label" { return CGSize(width: Double((node.patch.text ?? "").count) * 8 + 8, height: 20) }
        return proposal.resolved(.zero)
    }

    @Test func testSplitPaneContentIsLaidOutWithinEachNativePaneSize() {
        var frames: [String: CGRect] = [:]
        // The native split would allocate these pane sizes; sizeOf reports them back to the engine.
        let paneSizes: [String: CGSize] = ["sidebar": CGSize(width: 200, height: 600),
                                           "detail": CGSize(width: 600, height: 600)]
        let engine = LayoutEngine(
            measureLeaf: Self.measure,
            setFrame: { node, rect in frames[node.id] = rect },
            sizeOf: { paneSizes[$0.id] ?? .zero })

        let sidebar = RenderNode(id: "sidebar", component: ContainerComponent.vstack(), children: [
            RenderNode(id: "srow", component: PrimitiveLeafComponent(WidgetKey("label")), patch: WidgetPatch(text: "Item")),
        ])
        let detail = RenderNode(id: "detail", component: ContainerComponent.vstack(), children: [
            RenderNode(id: "dlabel", component: PrimitiveLeafComponent(WidgetKey("label")), patch: WidgetPatch(text: "Detail")),
        ])
        let split = RenderNode(id: "split", component: SplitViewComponent(), children: [sidebar, detail])

        engine.place(split, CGRect(x: 0, y: 0, width: 800, height: 600))

        // The split fills the window; the panes themselves are NOT reframed (the toolkit owns that), so
        // no frame is recorded for "sidebar"/"detail".
        #expect(frames["split"] == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(frames["sidebar"] == nil)
        #expect(frames["detail"] == nil)
        // Each pane's content is laid out top-leading within the pane's native size (matching a SwiftUI
        // split's sidebar/detail content). "Item" → 4*8+8 = 40 wide; "Detail" → 6*8+8 = 56 wide.
        #expect(frames["srow"] == CGRect(x: 0, y: 0, width: 40, height: 20))
        #expect(frames["dlabel"] == CGRect(x: 0, y: 0, width: 56, height: 20))
    }

    @Test func testNestedStackInsidePaneComposes() {
        var frames: [String: CGRect] = [:]
        let engine = LayoutEngine(
            measureLeaf: Self.measure,
            setFrame: { node, rect in frames[node.id] = rect },
            sizeOf: { _ in CGSize(width: 400, height: 300) })  // single pane size

        let pane = RenderNode(id: "pane", component: ContainerComponent.vstack(), children: [
            RenderNode(id: "row", component: ContainerComponent.hstack(spacing: 0), patch: WidgetPatch(spacing: 0), children: [
                RenderNode(id: "a", component: PrimitiveLeafComponent(WidgetKey("label")), patch: WidgetPatch(text: "A")),
                RenderNode(id: "b", component: PrimitiveLeafComponent(WidgetKey("label")), patch: WidgetPatch(text: "B")),
            ]),
        ])
        let split = RenderNode(id: "split", component: SplitViewComponent(), children: [pane])
        engine.place(split, CGRect(x: 0, y: 0, width: 400, height: 300))

        // Inside the pane: a 0-spacing HStack lays "A" (16) then "B" (16) at x = 0 and 16.
        #expect(frames["a"] == CGRect(x: 0, y: 0, width: 16, height: 20))
        #expect(frames["b"] == CGRect(x: 16, y: 0, width: 16, height: 20))
    }
}
