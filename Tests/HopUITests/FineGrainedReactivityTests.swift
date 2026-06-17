// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
import Observation
@testable import HopUI

// Tests that HopUI's reactivity is BOTH complete (no under-invalidation: every change that should be
// visible is) AND minimal (no over-invalidation: nothing re-runs that didn't need to). Body re-runs are
// counted via `BodyEvalTracker`; UI correctness via the mock toolkit's live labels. See
// `project_hopui_finegrained_reactivity`.

// MARK: - Fixtures: nested @State at three depths

@MainActor private struct Leaf: View {
    @State var x = 0
    var body: some View {
        VStack { Text("leaf=\(x)"); Button("leaf+") { x += 1 } }
    }
}

@MainActor private struct Middle: View {
    @State var y = 0
    var body: some View {
        VStack { Text("mid=\(y)"); Button("mid+") { y += 1 }; Leaf() }
    }
}

@MainActor private struct StaticSibling: View {
    var body: some View { Text("sibling") }
}

@MainActor private struct DeepRoot: View {
    @State var z = 0
    var body: some View {
        VStack { Text("root=\(z)"); Button("root+") { z += 1 }; Middle(); StaticSibling() }
    }
}

// MARK: - Fixtures: environment

@MainActor private struct EnvReader: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Text("scheme=\(scheme == .dark ? "dark" : "light")") }
}

@MainActor private struct EnvIgnorer: View {
    @State private var taps = 0
    var body: some View { Button("ignore-\(taps)") { taps += 1 } }   // reads no environment
}

@MainActor private struct EnvRoot: View {
    @State var dark = false
    var body: some View {
        VStack {
            Button("toggleScheme") { dark.toggle() }
            EnvReader()
            EnvIgnorer()
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

// MARK: - Fixtures: @Observable

@Observable @MainActor private final class Counts { var a = 0; var b = 0 }

@MainActor private struct AReader: View {
    let model: Counts
    var body: some View { Text("a=\(model.a)") }
}

@MainActor private struct BReader: View {
    let model: Counts
    var body: some View { Text("b=\(model.b)") }
}

@MainActor private struct ObservableRoot: View {
    @State var model = Counts()
    var body: some View {
        VStack {
            Button("bumpA") { model.a += 1 }
            Button("bumpB") { model.b += 1 }
            AReader(model: model)
            BReader(model: model)
        }
    }
}

// MARK: - Fixtures: preferences under memoization

@MainActor private struct Counter2: View {
    @State var n = 0
    var body: some View { Button("count-\(n)") { n += 1 } }
}

@MainActor private struct ToolbarOwner: View {
    var body: some View {
        Text("owns toolbar")
            .toolbar { Button("ToolbarButton") {} }
    }
}

@MainActor private struct PrefsRoot: View {
    @State var dark = false
    var body: some View {
        VStack {
            Button("toggleScheme") { dark.toggle() }
            Counter2()       // changes independently; must NOT drop the toolbar/scheme
            ToolbarOwner()   // contributes a toolbar item from a subtree that will be memoized
        }
        .preferredColorScheme(dark ? .dark : .light)
    }
}

@MainActor @Suite struct FineGrainedReactivityTests {
    private func button(_ toolkit: MockToolkit, _ title: String) -> MockWidget? {
        toolkit.widgets.first { $0.kind == "button" && $0.title == title }
    }
    private func tap(_ toolkit: MockToolkit, _ title: String) throws {
        try #require(button(toolkit, title)).action?()
        toolkit.drainMainThread()
    }

    // MARK: minimal recompute — a state change re-runs exactly one body (the changed one), like SwiftUI

    @Test func testStateChangeRecomputesOnlyTheChangedBody() throws {
        BodyEvalTracker.enabled = true
        defer { BodyEvalTracker.enabled = false }
        BodyEvalTracker.reset()

        let toolkit = MockToolkit()
        runHopApp(DeepRoot(), toolkit: toolkit, title: "t")

        // Initial mount: every composite body runs exactly once.
        #expect(BodyEvalTracker.count(type: "DeepRoot") == 1)
        #expect(BodyEvalTracker.count(type: "Middle") == 1)
        #expect(BodyEvalTracker.count(type: "Leaf") == 1)
        #expect(BodyEvalTracker.count(type: "StaticSibling") == 1)

        // A LEAF change: only Leaf re-runs. No ancestor (Middle/DeepRoot) and no sibling re-runs.
        BodyEvalTracker.reset()
        try tap(toolkit, "leaf+")
        #expect(toolkit.liveLabels().contains("leaf=1"))   // complete: UI reflects the change
        #expect(BodyEvalTracker.count(type: "Leaf") == 1)  // minimal: only the changed body
        #expect(BodyEvalTracker.count(type: "Middle") == 0)
        #expect(BodyEvalTracker.count(type: "DeepRoot") == 0)
        #expect(BodyEvalTracker.count(type: "StaticSibling") == 0)
        #expect(BodyEvalTracker.total == 1)

        // A MIDDLE change: only Middle re-runs (not its parent, not its Leaf child).
        BodyEvalTracker.reset()
        try tap(toolkit, "mid+")
        #expect(toolkit.liveLabels().contains("mid=1"))
        #expect(BodyEvalTracker.count(type: "Middle") == 1)
        #expect(BodyEvalTracker.count(type: "Leaf") == 0)
        #expect(BodyEvalTracker.count(type: "DeepRoot") == 0)
        #expect(BodyEvalTracker.total == 1)

        // A ROOT change: only DeepRoot re-runs (its unchanged children stay memoized).
        BodyEvalTracker.reset()
        try tap(toolkit, "root+")
        #expect(toolkit.liveLabels().contains("root=1"))
        #expect(BodyEvalTracker.count(type: "DeepRoot") == 1)
        #expect(BodyEvalTracker.count(type: "Middle") == 0)
        #expect(BodyEvalTracker.count(type: "Leaf") == 0)
        #expect(BodyEvalTracker.total == 1)

        // Earlier state persisted across all of the above (Leaf still shows 1).
        #expect(toolkit.liveLabels().contains("leaf=1"))
    }

    // MARK: environment — a change re-runs exactly the descendants that read it, and they reflect it

    @Test func testEnvironmentChangeIsPreciseAndComplete() throws {
        BodyEvalTracker.enabled = true
        defer { BodyEvalTracker.enabled = false }

        let toolkit = MockToolkit()
        runHopApp(EnvRoot(), toolkit: toolkit, title: "t")
        #expect(toolkit.liveLabels().contains("scheme=light"))

        BodyEvalTracker.reset()
        try tap(toolkit, "toggleScheme")

        // Complete: the env reader updated to the new value (NO under-invalidation — the bug option (A)
        // was chosen to prevent: a memoized subtree going stale on an ancestor environment change).
        #expect(toolkit.liveLabels().contains("scheme=dark"))
        // Precise: EnvRoot re-ran (it reads `dark` to set the environment) and the env reader re-ran;
        // the env-IGNORING sibling did NOT (minimal over-invalidation).
        #expect(BodyEvalTracker.count(type: "EnvReader") == 1)
        #expect(BodyEvalTracker.count(type: "EnvIgnorer") == 0)
    }

    // MARK: @Observable — a property mutation re-runs exactly the views that read that property

    @Test func testObservableChangeReRunsOnlyReadersOfThatProperty() throws {
        BodyEvalTracker.enabled = true
        defer { BodyEvalTracker.enabled = false }

        let toolkit = MockToolkit()
        runHopApp(ObservableRoot(), toolkit: toolkit, title: "t")
        #expect(toolkit.liveLabels().contains("a=0"))
        #expect(toolkit.liveLabels().contains("b=0"))

        // Mutate only `a`: only AReader re-runs. BReader (reads `b`) and the root (reads neither) don't.
        BodyEvalTracker.reset()
        try tap(toolkit, "bumpA")
        #expect(toolkit.liveLabels().contains("a=1"))   // complete
        #expect(toolkit.liveLabels().contains("b=0"))
        #expect(BodyEvalTracker.count(type: "AReader") == 1)   // precise
        #expect(BodyEvalTracker.count(type: "BReader") == 0)
        #expect(BodyEvalTracker.count(type: "ObservableRoot") == 0)
        #expect(BodyEvalTracker.total == 1)

        // Mutate only `b`: now only BReader re-runs.
        BodyEvalTracker.reset()
        try tap(toolkit, "bumpB")
        #expect(toolkit.liveLabels().contains("b=1"))
        #expect(BodyEvalTracker.count(type: "BReader") == 1)
        #expect(BodyEvalTracker.count(type: "AReader") == 0)
        #expect(BodyEvalTracker.total == 1)
    }

    // MARK: preferences survive memoization (the other half of option (A): preferences as graph data,
    // not global side effects, so a memoized subtree still contributes them)

    @Test func testPreferencesSurviveAnUnrelatedChange() throws {
        let toolkit = MockToolkit()
        runHopApp(PrefsRoot(), toolkit: toolkit, title: "t")

        // Both preferences are installed initially.
        #expect(toolkit.appliedColorScheme == .light)
        #expect(toolkit.toolbarItems.contains { if case .button(let t, _) = $0.kind { return t == "ToolbarButton" }; return false })

        // Change an UNRELATED subtree (the counter). The toolbar owner's subtree is memoized (not re-run),
        // yet its toolbar item must NOT be lost — preferences are collected from the live tree, not via a
        // side effect that only a re-run would re-emit.
        try tap(toolkit, "count-0")
        #expect(toolkit.liveLabels().isEmpty == false)
        #expect(toolkit.toolbarItems.contains { if case .button(let t, _) = $0.kind { return t == "ToolbarButton" }; return false },
                "toolbar item lost after an unrelated subtree changed — preference dropped by memoization")
        #expect(toolkit.appliedColorScheme == .light)

        // Changing the preference's own source updates it.
        try tap(toolkit, "toggleScheme")
        #expect(toolkit.appliedColorScheme == .dark)
        #expect(toolkit.toolbarItems.contains { if case .button(let t, _) = $0.kind { return t == "ToolbarButton" }; return false })
    }

    // MARK: removed views are torn down (state resets on re-add), with no stale recompute

    @Test func testRemovedSubtreeIsTornDownAndStateResets() throws {
        BodyEvalTracker.enabled = true
        defer { BodyEvalTracker.enabled = false }

        let toolkit = MockToolkit()
        runHopApp(RootWithToggle(), toolkit: toolkit, title: "t")
        try tap(toolkit, "leaf+")
        #expect(toolkit.liveLabels().contains("leaf=1"))

        try tap(toolkit, "hide")                                  // remove the Leaf subtree
        #expect(!toolkit.liveLabels().contains { $0.hasPrefix("leaf=") })

        BodyEvalTracker.reset()
        try tap(toolkit, "hide")                                  // re-add it
        #expect(toolkit.liveLabels().contains("leaf=0"))          // state reset (fresh), not the old "leaf=1"
        #expect(BodyEvalTracker.count(type: "Leaf") == 1)         // re-created exactly once
    }
}

@MainActor private struct RootWithToggle: View {
    @State var show = true
    var body: some View {
        VStack {
            Button("hide") { show.toggle() }
            if show { Leaf() }
        }
    }
}

// MARK: - Phase 2/3 fixtures: incremental reconcile + layout

@MainActor private struct ShapeHolder: View {
    var body: some View { Rectangle().fill(.red).frame(width: 10, height: 10) }
}

@MainActor private struct ReconcileRoot: View {
    @State var n = 0
    var body: some View {
        VStack {
            Button("bump-\(n)") { n += 1 }
            ShapeHolder()   // unchanged subtree — its widget must not be re-configured / re-measured
        }
    }
}

extension FineGrainedReactivityTests {
    // Phase 2: an unchanged subtree is not re-reconciled. `configureShape` is called unconditionally per
    // reconcile, so if the shape subtree were walked it would re-emit a "shape" op; the revision skip
    // prevents that — while the changed button IS updated (no under-invalidation).
    @Test func testReconcileSkipsUnchangedSubtree() throws {
        let toolkit = MockToolkit()
        runHopApp(ReconcileRoot(), toolkit: toolkit, title: "t")
        #expect(toolkit.ops.contains("shape"))   // built on mount

        toolkit.clearOps()
        try tap(toolkit, "bump-0")
        #expect(button(toolkit, "bump-1") != nil)             // changed widget updated (complete)
        #expect(!toolkit.ops.contains("shape"),               // unchanged shape subtree skipped (minimal)
                "unchanged shape subtree was re-reconciled")
    }

    // Phase 3: an unchanged subtree's leaves are not re-measured through the toolkit (the size cache
    // serves them); the changed subtree is re-measured and updates.
    @Test func testLayoutDoesNotReMeasureUnchangedSubtrees() throws {
        let toolkit = MockToolkit()
        runHopApp(DeepRoot(), toolkit: toolkit, title: "t")
        #expect(toolkit.measuredLabels.contains("sibling"))   // measured on first layout

        toolkit.clearMeasured()
        try tap(toolkit, "leaf+")
        #expect(toolkit.liveLabels().contains("leaf=1"))      // complete
        #expect(toolkit.measuredLabels.contains("leaf=1"))    // changed leaf re-measured
        #expect(!toolkit.measuredLabels.contains("sibling"),  // off-path subtree NOT re-measured
                "an unchanged sibling subtree was re-measured")
    }
}
