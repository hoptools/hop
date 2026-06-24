// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

// `Grid`/`GridRow` layout. The algorithm runs entirely in the LayoutEngine (a 2-pass measure → place over
// `.grid`/`.gridRow` nodes), so the core tests drive the engine directly with deterministic stub measures
// (a label is `text.count*8+8` wide × 20 tall; a `.separator` is a greedy divider — fills its proposal,
// 4pt tall when unconstrained). The view-level tests then confirm the `Grid`/`GridRow` views and the cell
// modifiers wire through the full reconcile path against a MockToolkit.
@MainActor @Suite struct GridTests {

    // MARK: deterministic engine stubs

    private static func measure(_ node: RenderNode, _ proposal: ProposedViewSize) -> CGSize {
        switch node.component.widgetKey {
        case .label:
            return CGSize(width: Double((node.patch.text ?? "").count) * 8 + 8, height: 20)
        case .separator:
            // A greedy divider: fills the proposed extent on each axis, defaulting to 0×4 when unconstrained.
            return proposal.resolved(CGSize(width: 0, height: 4))
        default:
            return proposal.resolved(.zero)
        }
    }

    private func engine(_ frames: @escaping (String, CGRect) -> Void) -> LayoutEngine {
        LayoutEngine(measureLeaf: Self.measure, setFrame: { node, rect in frames(node.id, rect) })
    }

    /// A label cell with the given id/text.
    private func label(_ id: String, _ text: String) -> RenderNode {
        RenderNode(id: id, component: PrimitiveLeafComponent(.label), patch: WidgetPatch(text: text))
    }
    /// A greedy divider cell with the given id.
    private func divider(_ id: String) -> RenderNode {
        RenderNode(id: id, component: PrimitiveLeafComponent(.separator))
    }
    private func gridRow(_ id: String, _ cells: [RenderNode], alignment: VerticalAlignment? = nil) -> RenderNode {
        RenderNode(id: id, component: ContainerComponent.gridRow(alignment), children: cells)
    }
    private func grid(_ id: String, alignment: Alignment = .center, h: Double? = nil, v: Double? = nil,
                      _ lines: [RenderNode]) -> RenderNode {
        RenderNode(id: id, component: ContainerComponent.grid(
            GridConfig(alignment: alignment, horizontalSpacing: h, verticalSpacing: v)), children: lines)
    }

    // MARK: column alignment

    @Test func testColumnsAlignToWidestCellAcrossRows() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        // Row 0: "A"(16) "Longer"(56); Row 1: "BB"(24) "X"(16). hSpacing/vSpacing = 10.
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [label("r0c0", "A"), label("r0c1", "Longer")]),
            gridRow("r1", [label("r1c0", "BB"), label("r1c1", "X")]),
        ])
        e.place(g, CGRect(x: 0, y: 0, width: 400, height: 400))

        // col0 = max(16,24)=24, col1 = max(56,16)=56 → col1 starts at 24+10 = 34.
        #expect(frames["r0c1"]?.minX == 34)
        #expect(frames["r1c1"]?.minX == 34)   // the short "X" aligns under the wide "Longer"
        // col0 cells are top-leading within their 24-wide column (each keeps its intrinsic width).
        #expect(frames["r0c0"] == CGRect(x: 0, y: 0, width: 16, height: 20))
        #expect(frames["r1c0"] == CGRect(x: 0, y: 0, width: 24, height: 20))
        // The grid rows are framed full-width (90 = 24+56+10) and stacked with vSpacing.
        #expect(frames["r0"] == CGRect(x: 0, y: 0, width: 90, height: 20))
        #expect(frames["r1"] == CGRect(x: 0, y: 30, width: 90, height: 20))
    }

    @Test func testGridSizeIsContentDriven() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [label("r0c0", "A"), label("r0c1", "Longer")]),
            gridRow("r1", [label("r1c0", "BB"), label("r1c1", "X")]),
        ])
        let size = e.size(g, .unspecified)
        #expect(size == CGSize(width: 90, height: 50))   // (24+56+10) × (20+20+10)
    }

    @Test func testGridColumnAlignmentOverridesWholeColumn() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        // Grid default is leading. ONE cell in column 1 declares .gridColumnAlignment(.trailing); that
        // override applies to the WHOLE column — including a different row's column-1 cell that does NOT
        // declare it. Column 0 keeps the grid default (leading).
        var x1 = label("x1", "X")            // col1, declares the trailing override
        x1.gridColumnAlignment = .trailing
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [label("a", "A"), x1]),
            gridRow("r1", [label("b", "BBBB"), label("wide", "WIDECOL")]),  // "WIDECOL"(64) sets col1 width
            gridRow("r2", [label("c", "CCCC"), label("y", "Y")]),           // "Y"(16): no override of its own
        ])
        e.place(g, CGRect(x: 0, y: 0, width: 400, height: 400))

        // col0 = max("A"16,"BBBB"40,"CCCC"40)=40; col1 = max("X"16,"WIDECOL"64,"Y"16)=64; colX[1]=40+10=50.
        #expect(frames["a"]?.minX == 0)       // column 0 uses the grid default (leading)
        #expect(frames["x1"]?.minX == 98)     // 50 + (64-16): trailing, from its own override
        #expect(frames["y"]?.minX == 98)      // 50 + (64-16): trailing too — the override is per-COLUMN
    }

    // MARK: spanning

    @Test func testGridCellColumnsSpansSummedWidth() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        var sep = divider("sep")
        sep.gridCellColumns = 2
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [sep]),                                    // a spanning header (greedy, fills)
            gridRow("r1", [label("r1c0", "AAAA"), label("r1c1", "BB")]),
        ])
        // Place at the grid's natural size so there's no surplus to distribute (the spanning math is the
        // subject here; fill/distribution is covered separately).
        let sz = e.size(g, .unspecified)
        e.place(g, CGRect(origin: .zero, size: sz))

        // col0 = "AAAA"(40), col1 = "BB"(24); span-2 width = 40 + 24 + hSpacing(10) = 74.
        #expect(frames["sep"] == CGRect(x: 0, y: 0, width: 74, height: 4))
        // Spanning does NOT widen the columns: "BB" still starts at col1 = 40+10 = 50.
        #expect(frames["r1c1"]?.minX == 50)
    }

    @Test func testWideSpanningCellDoesNotWidenPopulatedColumns() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        var hdr = label("hdr", "AVeryLongHeaderTitle")   // far wider than the two columns it spans
        hdr.gridCellColumns = 2
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [hdr]),
            gridRow("r1", [label("a", "aa"), label("b", "bb")]),   // both columns populated by span-1 cells
        ])
        let sz = e.size(g, .unspecified)
        e.place(g, CGRect(origin: .zero, size: sz))

        // col0="aa"(24), col1="bb"(24). A spanning cell never widens already-populated columns, so "bb"
        // still starts at col1 = 24 + 10 = 34 (the long header simply overflows the combined width).
        #expect(frames["b"]?.minX == 34)
    }

    @Test func testHugeSpansClampInsteadOfOverflowingOrOverAllocating() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        // Two cells each with an enormous span — without clamping, `col += span` traps on overflow and the
        // column arrays balloon. The effective span is clamped to the cell ceiling, so this lays out fine.
        var a = label("a", "A"); a.gridCellColumns = Int.max
        var b = label("b", "B"); b.gridCellColumns = Int.max
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [a, b]),
        ])
        e.place(g, CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(frames["r0"] != nil)   // reached here without trapping / exhausting memory
    }

    // MARK: loose child

    @Test func testLooseChildSpansFullWidth() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [label("r0c0", "AAAA"), label("r0c1", "BB")]),
            divider("loose"),                                        // a loose full-width divider
        ])
        let sz = e.size(g, .unspecified)                            // natural size → no surplus to spread
        e.place(g, CGRect(origin: .zero, size: sz))

        // Grid width = 40 + 24 + 10 = 74; the loose divider spans it, below the row (20 + vSpacing 10 = 30).
        #expect(frames["loose"] == CGRect(x: 0, y: 30, width: 74, height: 4))
    }

    // MARK: anchor

    @Test func testGridCellAnchorOverridesAlignment() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        var x = label("x", "X")
        x.gridCellAnchor = .bottomTrailing
        // A tall sibling (60pt) makes the row taller than "X", so the anchor's VERTICAL component is exercised
        // (not just the horizontal one).
        var tall = label("tall", "T")
        tall.layout = LayoutInfo(modifiers: [.frame(FrameSpec(width: 30, height: 60))])
        let g = grid("g", alignment: .center, h: 10, v: 10, [
            gridRow("r0", [x, tall]),
            gridRow("r1", [label("r1c0", "WWWWWW"), label("r1c1", "Y")]),
        ])
        e.place(g, CGRect(x: 0, y: 0, width: 400, height: 400))

        // col0 = max("X"16, "WWWWWW"56) = 56; row0 height = max(20, 60) = 60.
        // anchor (1,1): ox = (56-16)*1 = 40, oy = (60-20)*1 = 40 — both axes pinned to bottom-trailing.
        #expect(frames["x"] == CGRect(x: 40, y: 40, width: 16, height: 20))
    }

    // MARK: unsized axes

    @Test func testGridCellUnsizedAxesUsesIntrinsicExtent() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        var sep = divider("sep")
        sep.gridCellUnsizedAxes = .horizontal              // don't stretch horizontally; still fill vertically
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [sep, label("r0c1", "PAD")]),
            gridRow("r1", [label("r1c0", "WIDECELL"), label("r1c1", "p")]),
        ])
        let sz = e.size(g, .unspecified)                  // natural size → col0 stays "WIDECELL" wide (72)
        e.place(g, CGRect(origin: .zero, size: sz))

        // col0 = "WIDECELL"(72); the divider keeps its intrinsic 0 width (not 72) but fills the 20pt row.
        #expect(frames["sep"]?.width == 0)
        #expect(frames["sep"]?.height == 20)
    }

    // MARK: fill & flexible-track distribution

    @Test func testGridFillsOfferedWidthAcrossFlexibleColumns() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        // A loose greedy divider makes EVERY column flexible → the grid fills the offered width and spreads
        // the surplus equally across the columns (matching SwiftUI's Divider-in-a-Grid behavior).
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [label("r0c0", "A"), label("r0c1", "BB")]),   // col0=16, col1=24
            divider("rule"),
        ])
        e.place(g, CGRect(x: 0, y: 0, width: 200, height: 200))

        // content width = 16 + 24 + 10 = 50; surplus 150 / 2 flexible columns = 75 each → col0 = 91.
        #expect(frames["r0c1"]?.minX == 101)        // col1 starts at 91 + hSpacing(10)
        #expect(frames["rule"]?.width == 200)        // the rule spans the full filled width
    }

    @Test func testGridFillsOfferedHeightAcrossFlexibleRows() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        var tall = label("tall", "T")
        tall.layout = LayoutInfo(modifiers: [.frame(FrameSpec(maxHeight: .infinity))])  // greedy-vertical
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("row0", [tall]),
            gridRow("row1", [label("r1cell", "B")]),
        ])
        e.place(g, CGRect(x: 0, y: 0, width: 100, height: 200))

        // content height = 20 + 20 + vSpacing(10) = 50; surplus 150 to the single flexible row → row0 = 170.
        #expect(frames["row1"]?.minY == 180)         // row1 starts at 170 + vSpacing(10)
    }

    /// col1 (the middle column) is flexible; col0 and col2 are fixed. The trailing fixed column's X
    /// position reveals how much col1 grew, so the assertion is unambiguous (no frame-centering subtlety).
    private func partialFlexGrid() -> RenderNode {
        var flex = label("flex", "BB")   // floor 24, flexible (.leading so its label hugs the column start)
        flex.layout = LayoutInfo(modifiers: [.frame(FrameSpec(maxWidth: .infinity, alignment: .leading))])
        return grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [label("c0", "AAAA"), flex, label("c2", "ZZ")]),   // 40, 24(flex), 24
        ])
    }

    @Test func testFillSurplusGoesOnlyToFlexibleColumns() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        e.place(partialFlexGrid(), CGRect(x: 0, y: 0, width: 200, height: 200))

        // content width = 40 + 24 + 24 + 2·10 = 108; surplus 92 → ALL to col1 → col1 = 24 + 92 = 116.
        #expect(frames["c0"] == CGRect(x: 0, y: 0, width: 40, height: 20))   // fixed col0 keeps content width
        #expect(frames["flex"]?.minX == 50)            // col1 starts at 40 + 10 (leading label at column start)
        #expect(frames["c2"]?.minX == 176)             // col2 pushed right by col1's growth: 40+10+116+10
    }

    /// A fixed-size shape cell (e.g. the demo's orange/green rects), built from a `.shape` leaf framed on
    /// both axes so the stub measures it deterministically.
    private func fixedRect(_ id: String, _ w: Double, _ h: Double = 24) -> RenderNode {
        var n = RenderNode(id: id, component: PrimitiveLeafComponent(.shape))
        n.layout = LayoutInfo(modifiers: [.frame(FrameSpec(width: w, height: h))])
        return n
    }

    @Test func testCellFramedOnOtherAxisStillMakesColumnFlexible() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        // The demo's "spanning banner": a shape with ONLY .frame(height:) is still horizontally greedy, so
        // its spanned columns are flexible and the grid fills the offered width (the regression the user hit:
        // a one-axis frame masked the other axis's greediness, so this grid never resized with the window).
        var banner = RenderNode(id: "banner", component: PrimitiveLeafComponent(.shape))
        banner.layout = LayoutInfo(modifiers: [.frame(FrameSpec(height: 36))])
        banner.gridCellColumns = 2
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [banner]),
            gridRow("r1", [fixedRect("c0", 160), fixedRect("c1", 180)]),   // fixed cells set the column floors
        ])
        e.place(g, CGRect(x: 0, y: 0, width: 500, height: 400))

        // content width = 160 + 180 + 10 = 350; offered 500 → surplus 150 split across BOTH flexible columns
        // (the banner spans both) = 75 each → col1 starts at (160+75)+10 = 245; the banner spans the full 500.
        #expect(frames["c1"]?.minX == 245)
        #expect(frames["banner"]?.width == 500)
    }

    @Test func testGridDoesNotShrinkBelowContentWhenOfferedLess() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        e.place(partialFlexGrid(), CGRect(x: 0, y: 0, width: 30, height: 200))  // offered LESS than content (108)

        // The `available.width > content` guard means no negative surplus: columns stay at content size.
        #expect(frames["c0"] == CGRect(x: 0, y: 0, width: 40, height: 20))
        #expect(frames["c2"]?.minX == 84)              // col2 at content position: 40+10+24+10 (col1 not shrunk)
    }

    // MARK: ragged rows

    @Test func testRaggedRowReservesTrailingColumns() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        // Row 0 has 3 cells (defines 3 columns); row 1 has only 1 — its trailing columns stay empty.
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [label("r0c0", "AA"), label("r0c1", "BB"), label("r0c2", "CC")]),
            gridRow("r1", [label("r1c0", "Z")]),
        ])
        e.place(g, CGRect(x: 0, y: 0, width: 400, height: 400))

        // All three columns are 24 wide ("AA"/"BB"/"CC"); the lone "Z" sits in column 0 only.
        #expect(frames["r0c2"]?.minX == 68)        // col2 = 24 + 10 + 24 + 10 = 68
        #expect(frames["r1c0"] == CGRect(x: 0, y: 0, width: 16, height: 20))
    }

    // MARK: grid inside a scroll view

    @Test func testGridInsideScrollKeepsColumnAlignment() {
        var frames: [String: CGRect] = [:]
        let e = engine { frames[$0] = $1 }
        let g = grid("g", alignment: .topLeading, h: 10, v: 10, [
            gridRow("r0", [label("r0c0", "A"), label("r0c1", "Longer")]),
            gridRow("r1", [label("r1c0", "BB"), label("r1c1", "X")]),
        ])
        let scroll = RenderNode(id: "scroll", component: ContainerComponent(.scroll, role: .scroll(axis: .vertical)),
                                children: [g])
        e.place(scroll, CGRect(x: 0, y: 0, width: 200, height: 200))

        // The grid keeps its content-driven column widths even when the scroll offers a larger viewport.
        #expect(frames["r0c1"]?.minX == 34)
        #expect(frames["r1c1"]?.minX == 34)
    }

    // MARK: view-level wiring (full reconcile through a MockToolkit)

    @MainActor private struct SimpleGridHost: View {
        var body: some View {
            Grid(alignment: .leading) {
                GridRow { Text("A"); Text("Longer") }
                GridRow { Text("BB"); Text("X") }
            }
        }
    }

    @Test func testGridViewRendersGridAndRowWidgets() {
        let toolkit = MockToolkit()
        runHopApp(SimpleGridHost(), toolkit: toolkit, title: "test")
        #expect(toolkit.widgets.contains { $0.kind == .grid })
        #expect(toolkit.widgets.filter { $0.kind == .gridRow }.count == 2)
        #expect(toolkit.liveLabels().contains("Longer"))
    }

    @Test func testGridViewColumnsAlignThroughFullPath() {
        let toolkit = MockToolkit()
        runHopApp(SimpleGridHost(), toolkit: toolkit, title: "test")
        // The second-column cells ("Longer" and "X") share a left edge (leading alignment).
        let longer = toolkit.widgets.first { $0.kind == .label && $0.text == "Longer" }?.frame
        let x = toolkit.widgets.first { $0.kind == .label && $0.text == "X" }?.frame
        #expect(longer?.minX != nil)
        #expect(longer?.minX == x?.minX)
    }

    @MainActor private struct SpanGridHost: View {
        var body: some View {
            Grid {   // default .center
                GridRow { Text("H").gridCellColumns(2) }
                GridRow { Text("AAAA"); Text("BB") }
            }
        }
    }

    @Test func testGridCellColumnsModifierAppliesThroughFullPath() {
        let toolkit = MockToolkit()
        runHopApp(SpanGridHost(), toolkit: toolkit, title: "test")
        // col0="AAAA"(40), col1="BB"(24), default hSpacing 8 → span-2 cell is 72 wide; "H"(16) centers at
        // (72-16)/2 = 28. (Without the span modifier it would sit in a 40-wide column at (40-16)/2 = 12.)
        let h = toolkit.widgets.first { $0.kind == .label && $0.text == "H" }?.frame
        #expect(h?.minX == 28)
    }
}
