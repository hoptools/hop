// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

// A nested view with its OWN local @State — the case that used to reset on every re-render.
@MainActor private struct Counter: View {
    @State var n = 0
    var body: some View {
        VStack {
            Text("n=\(n)")
            Button("inc") { n += 1 }
        }
    }
}

@MainActor private struct RootForcingReRender: View {
    @State var tick = 0
    var body: some View {
        VStack {
            Button("force") { tick += 1 }   // a root-state change forces a full re-render of the tree
            Counter()
        }
    }
}

@MainActor private struct RootWithVisibility: View {
    @State var show = true
    var body: some View {
        VStack {
            Button("toggle") { show.toggle() }
            if show { Counter() }
        }
    }
}

@MainActor private struct TwoCounters: View {
    var body: some View {
        VStack { Counter(); Counter() }
    }
}

@MainActor @Suite struct StateIdentityTests {
    private func button(_ toolkit: MockToolkit, _ title: String) -> MockWidget? {
        toolkit.widgets.first { $0.kind == "button" && $0.title == title }
    }

    @Test func testNestedStatePersistsAcrossReRender() throws {
        let toolkit = MockToolkit()
        runHopApp(RootForcingReRender(), toolkit: toolkit, title: "test")
        #expect(toolkit.liveLabels().contains("n=0"))

        try #require(button(toolkit, "inc")).action?()        // bump the nested counter
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("n=1"))

        // Force a full re-render via ROOT state. The Counter struct is recreated — its @State survives
        // because it's keyed to the view's identity, not the struct instance (this regressed before).
        try #require(button(toolkit, "force")).action?()
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("n=1"))         // persisted (was "n=0" before the fix)
    }

    @Test func testStateResetsWhenViewRemovedAndReadded() throws {
        let toolkit = MockToolkit()
        runHopApp(RootWithVisibility(), toolkit: toolkit, title: "test")
        try #require(button(toolkit, "inc")).action?()
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("n=1"))

        try #require(button(toolkit, "toggle")).action?()     // hide → Counter removed (swept)
        toolkit.drainMainThread()
        #expect(!toolkit.liveLabels().contains { $0.hasPrefix("n=") })

        try #require(button(toolkit, "toggle")).action?()     // show again → fresh state
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("n=0"))         // reset, not the old "n=1"
    }

    @Test func testSiblingsHaveIndependentState() throws {
        let toolkit = MockToolkit()
        runHopApp(TwoCounters(), toolkit: toolkit, title: "test")
        let incs = toolkit.widgets.filter { $0.kind == "button" && $0.title == "inc" }
        #expect(incs.count == 2)

        incs[0].action?()                                     // bump only the first sibling
        toolkit.drainMainThread()
        let counts = toolkit.liveLabels().filter { $0.hasPrefix("n=") }.sorted()
        #expect(counts == ["n=0", "n=1"])                     // independent: one bumped, one untouched
    }
}
