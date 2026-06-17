// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

// Verifies `.onTapGesture` wires a tap handler onto the wrapped widget and that firing it drives the
// normal reactive update loop (tap → @State mutation → re-render). The native recognizers (AppKit /
// GTK4 / Qt / WinUI) are exercised end-to-end via the demo's GesturePlayground; here we drive the Mock.
@MainActor @Suite struct GestureTests {
    private struct TapCounter: View {
        @State var count = 0
        var body: some View {
            VStack {
                Text("Count: \(count)")
                Rectangle().fill(.blue).frame(width: 100, height: 100)
                    .onTapGesture { count += 1 }
            }
        }
    }

    @Test func testOnTapGestureWiresHandlerAndIsReactive() throws {
        let toolkit = MockToolkit()
        runHopApp(TapCounter(), toolkit: toolkit, title: "t")

        // The tapped view (the shape) carries the handler with the requested tap count.
        let shape = try #require(toolkit.widgets.first { $0.kind == .shape })
        #expect(shape.tapCount == 1)
        #expect(shape.tapHandler != nil)

        func label() -> MockWidget? { toolkit.widgets.first { ($0.text ?? "").hasPrefix("Count:") } }
        #expect(label()?.text == "Count: 0")

        // Simulate a tap: the handler runs `count += 1`, which re-renders the label — exactly the path a
        // real NSClickGestureRecognizer / GtkGestureClick / Qt event filter / WinUI Tapped event drives.
        shape.tapHandler?()
        toolkit.drainMainThread()
        #expect(label()?.text == "Count: 1")

        shape.tapHandler?()
        toolkit.drainMainThread()
        #expect(label()?.text == "Count: 2")
    }

    private struct DoubleTap: View {
        @State var n = 0
        var body: some View { Text("n=\(n)").onTapGesture(count: 2) { n += 1 } }
    }

    @Test func testOnTapGestureCountIsCarried() throws {
        let toolkit = MockToolkit()
        runHopApp(DoubleTap(), toolkit: toolkit, title: "t")
        let label = try #require(toolkit.widgets.first { ($0.text ?? "").hasPrefix("n=") })
        #expect(label.tapCount == 2)        // count flows through to the recognizer (here, the Mock)
    }
}
