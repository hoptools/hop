// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

// Verifies LazyVStack/LazyHStack virtualization: with thousands of rows inside a ScrollView, only the
// visible window (plus a small buffer) is ever materialized, the lazy stack is still sized to the FULL
// content (so the scrollbar is correct), and scrolling re-materializes a different window. The mock
// simulates scrolling by invoking the scroll widget's handler.
@MainActor @Suite struct LazyStackTests {
    /// The texts of the currently-live (materialized) rows under the lazy stack.
    private func liveRows(_ backend: MockBackend) -> [String] {
        guard let lazy = backend.widgets.first(where: { $0.kind == .lazyStack }) else { return [] }
        return lazy.children.compactMap { $0.text }
    }

    @Test func testLazyVStackMaterializesOnlyVisibleRows() throws {
        let backend = MockBackend()  // 800×600 content area
        runHopApp(ScrollView {
            LazyVStack {
                ForEach(0 ..< 1000, id: \.self) { i in Text("Row \(i)") }
            }
        }, backend: backend, title: "t")
        backend.drainMainThread()  // converge the viewport-size + row-extent feedback

        let rows = liveRows(backend)
        // Only a screenful (plus buffer) is live — nowhere near 1000.
        #expect(rows.count < 60)
        #expect(rows.contains("Row 0"))
        #expect(!rows.contains("Row 500"))
        // And we never *created* anywhere near 1000 label widgets.
        #expect(backend.widgets.filter { $0.kind == .label }.count < 100)
    }

    @Test func testLazyVStackIsSizedToFullContentForScrolling() throws {
        let backend = MockBackend()
        runHopApp(ScrollView {
            LazyVStack { ForEach(0 ..< 1000, id: \.self) { i in Text("Row \(i)") } }
        }, backend: backend, title: "t")
        backend.drainMainThread()

        // The lazy stack reports the full content height (≈ 1000 rows tall), far taller than the 600
        // viewport, so the native scroll bar reflects the whole list.
        let lazy = try #require(backend.widgets.first { $0.kind == .lazyStack })
        #expect((lazy.frame?.height ?? 0) > 20000)
    }

    @Test func testScrollingReMaterializesTheVisibleWindow() throws {
        let backend = MockBackend()
        runHopApp(ScrollView {
            LazyVStack { ForEach(0 ..< 1000, id: \.self) { i in Text("Row \(i)") } }
        }, backend: backend, title: "t")
        backend.drainMainThread()
        #expect(liveRows(backend).contains("Row 0"))

        // Simulate a scroll down by 500pt and let the feedback re-render.
        let scroll = try #require(backend.widgets.first { $0.kind == .scroll })
        scroll.scrollHandler?(CGSize(width: 0, height: 500))
        backend.drainMainThread()

        let rows = liveRows(backend)
        #expect(rows.contains("Row 30"))   // now in view
        #expect(!rows.contains("Row 0"))   // scrolled out and recycled
    }

    @Test func testLazyVStackBelowAHeaderWindowsRelativeToItself() throws {
        let backend = MockBackend()  // 800×600
        runHopApp(ScrollView {
            VStack(spacing: 0) {
                Text("Header").frame(height: 200)
                LazyVStack(spacing: 0) { ForEach(0 ..< 1000, id: \.self) { Text("Row \($0)") } }
            }
        }, backend: backend, title: "t")
        backend.drainMainThread()
        backend.drainMainThread()  // converge the row-extent + content-origin feedback
        #expect(liveRows(backend).contains("Row 0"))  // top of the list is visible below the header

        // Scroll past the header and into the list; the window must follow (relative to the lazy stack's
        // own origin), not stay stuck at the top.
        let scroll = try #require(backend.widgets.first { $0.kind == .scroll })
        scroll.scrollHandler?(CGSize(width: 0, height: 600))
        backend.drainMainThread()
        backend.drainMainThread()
        let rows = liveRows(backend)
        #expect(rows.contains("Row 20"))   // now in view (offset 600 − header 200 = 400 ⇒ row ~20)
        #expect(!rows.contains("Row 0"))   // scrolled out
    }

    @Test func testLazyHStackMaterializesOnlyVisibleColumns() throws {
        let backend = MockBackend()
        runHopApp(ScrollView(.horizontal) {
            LazyHStack { ForEach(0 ..< 1000, id: \.self) { i in Text("C\(i)") } }
        }, backend: backend, title: "t")
        backend.drainMainThread()

        let cols = liveRows(backend)
        #expect(cols.count < 80)
        #expect(cols.contains("C0"))
        #expect(!cols.contains("C500"))
    }
}
