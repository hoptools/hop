// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

// Verifies HopUI's framework-owned layout engine end to end: the MockBackend gives leaves deterministic
// intrinsic sizes (a label is `text.count * 8 + 8` wide, 20 tall — see MockBackend.measure), so the
// frames the engine records via `setFrame` are exactly predictable. These exercise the box model:
// VStack/HStack stacking + spacing + cross-axis alignment, Spacer flex, ZStack overlay, and the
// `.padding` / `.frame` modifiers.
@MainActor @Suite struct LayoutTests {
    /// Find a recorded widget by its label text.
    private func label(_ text: String, _ backend: MockBackend) throws -> MockWidget {
        try #require(backend.widgets.first { $0.text == text })
    }

    @Test func testVStackStacksVerticallyWithDefaultSpacingAndCentersCrossAxis() throws {
        let backend = MockBackend()
        runHopApp(VStack { Text("A"); Text("BB") }, backend: backend, title: "t")
        // "A" → 1*8+8 = 16 wide; "BB" → 2*8+8 = 24 wide; both 20 tall. Default spacing is 8.
        // Cross axis (width) is centered within the widest child (24).
        #expect(try label("A", backend).frame == CGRect(x: 4, y: 0, width: 16, height: 20))
        #expect(try label("BB", backend).frame == CGRect(x: 0, y: 28, width: 24, height: 20))
    }

    @Test func testHStackSpacerPushesTrailingChildToTheEdge() throws {
        let backend = MockBackend()  // content area is 800×600
        runHopApp(HStack { Text("A"); Spacer(); Text("B") }, backend: backend, title: "t")
        // Both labels are 16 wide; the Spacer absorbs all leftover width (no spacing around a Spacer),
        // so "A" pins to the left and "B" to the right edge: 800 - 16 = 784.
        #expect(try label("A", backend).frame?.minX == 0)
        #expect(try label("B", backend).frame?.minX == 784)
    }

    @Test func testPaddingOffsetsAndGrowsTheContent() throws {
        let backend = MockBackend()
        runHopApp(VStack { Text("A").padding(10) }, backend: backend, title: "t")
        // The padded label occupies a 36×40 slot (16+20 / 20+20); the leaf is inset by 10 on every edge.
        #expect(try label("A", backend).frame == CGRect(x: 10, y: 10, width: 16, height: 20))
    }

    @Test func testFrameSizesTheBoxAndCentersContent() throws {
        let backend = MockBackend()
        runHopApp(VStack { Text("A").frame(width: 100, height: 50) }, backend: backend, title: "t")
        // The 16×20 label is centered (default alignment) in its 100×50 frame: x=(100-16)/2, y=(50-20)/2.
        #expect(try label("A", backend).frame == CGRect(x: 42, y: 15, width: 16, height: 20))
    }

    @Test func testFrameMaxWidthInfinityFillsOfferedWidth() throws {
        let backend = MockBackend()
        runHopApp(VStack { Text("A").frame(maxWidth: .infinity) }, backend: backend, title: "t")
        // A flexible frame takes the full offered width (800); the 16-wide label centers within it at
        // x = (800 - 16) / 2 = 392, keeping its intrinsic 16×20 size.
        #expect(try label("A", backend).frame == CGRect(x: 392, y: 0, width: 16, height: 20))
    }

    @Test func testZStackOverlaysChildrenSizedToMaxAndAligned() throws {
        let backend = MockBackend()
        runHopApp(ZStack { Rectangle().frame(width: 40, height: 40); Text("A") }, backend: backend, title: "t")
        // The ZStack is 40×40 (its largest child). The rectangle fills it; the 16×20 label centers within.
        let rect = try #require(backend.widgets.first { $0.kind == .shape })
        #expect(rect.frame == CGRect(x: 0, y: 0, width: 40, height: 40))
        #expect(try label("A", backend).frame == CGRect(x: 12, y: 10, width: 16, height: 20))
    }

    @Test func testBackgroundCoversPaddingAndFrame() throws {
        let backend = MockBackend()
        runHopApp(VStack { Text("X").padding(10).background(.yellow) }, backend: backend, title: "t")
        // "X" is 16×20; padding(10) makes the box 36×40. `.background` wraps the padded view in a container
        // sized to it, so the yellow covers the padding (not just the 16×20 text).
        let bg = try #require(backend.widgets.first { $0.backgroundColor == .yellow })
        #expect(bg.kind == .zstack)
        #expect(bg.frame == CGRect(x: 0, y: 0, width: 36, height: 40))
        // The text sits inset by the padding within the background container.
        #expect(try label("X", backend).frame == CGRect(x: 10, y: 10, width: 16, height: 20))
    }

    @Test func testNestedStacksComposePositions() throws {
        let backend = MockBackend()
        runHopApp(VStack(spacing: 0) {
            HStack(spacing: 0) { Text("A"); Text("B") }   // 16 + 16 = 32 wide, 20 tall
            Text("CC")                                     // 24 wide, 20 tall
        }, backend: backend, title: "t")
        // Row 1 is 32 wide (widest), so it defines the VStack's cross extent; "CC" (24) centers under it.
        #expect(try label("A", backend).frame == CGRect(x: 0, y: 0, width: 16, height: 20))
        #expect(try label("B", backend).frame == CGRect(x: 16, y: 0, width: 16, height: 20))
        #expect(try label("CC", backend).frame == CGRect(x: 4, y: 20, width: 24, height: 20))
    }
}
