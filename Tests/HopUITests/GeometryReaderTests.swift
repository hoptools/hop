// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

// GeometryReader feeds its laid-out size back into its content through a graph source: the first render
// builds content at size 0, the layout pass reports the real size, and the deferred re-render rebuilds
// content with it. These tests drain the mock's main-loop queue to run that deferred pass, then assert
// the content reflects the measured geometry.
@MainActor @Suite struct GeometryReaderTests {
    @Test func testRootGeometryReaderReportsWindowSize() throws {
        let backend = MockBackend()  // content area is 800×600
        runHopApp(GeometryReader { proxy in
            Text("\(Int(proxy.size.width))x\(Int(proxy.size.height))")
        }, backend: backend, title: "t")
        backend.drainMainThread()  // run the deferred re-render triggered by the size feedback

        // A GeometryReader is greedy, so at the root it fills the window; its content sees 800×600.
        #expect(backend.widgets.contains { $0.text == "800x600" })
    }

    @Test func testFramedGeometryReaderReportsFrameSize() throws {
        let backend = MockBackend()
        runHopApp(VStack {
            GeometryReader { proxy in
                Text("\(Int(proxy.size.width))x\(Int(proxy.size.height))")
            }
            .frame(width: 300, height: 200)
        }, backend: backend, title: "t")
        backend.drainMainThread()

        // The frame constrains the reader to 300×200; its content sees exactly that.
        #expect(backend.widgets.contains { $0.text == "300x200" })
    }

    @Test func testGeometryReaderPlacesChildAtNaturalSizeTopLeading() throws {
        let backend = MockBackend()
        runHopApp(GeometryReader { _ in Text("Hi") }, backend: backend, title: "t")
        backend.drainMainThread()
        // The child keeps its natural size (24×20 for "Hi") at the top-leading corner — it is NOT stretched
        // to fill the reader's 800×600 bounds (matching SwiftUI).
        let t = try #require(backend.widgets.first { $0.text == "Hi" })
        #expect(t.frame == CGRect(x: 0, y: 0, width: 24, height: 20))
    }

    @Test func testGeometryReaderReRendersOnlyWhenSizeChanges() throws {
        // The size feedback must converge: after the content settles at the measured size, draining again
        // performs no further re-render (the size is unchanged, so no new flush is scheduled).
        let backend = MockBackend()
        runHopApp(GeometryReader { proxy in Text("\(Int(proxy.size.width))") }, backend: backend, title: "t")
        backend.drainMainThread()
        let settled = GraphContext.flushCount
        backend.drainMainThread()  // nothing pending should remain → no additional flush
        #expect(GraphContext.flushCount == settled)
        #expect(backend.widgets.contains { $0.text == "800" })
    }
}
