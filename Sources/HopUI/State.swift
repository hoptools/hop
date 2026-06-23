// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import HopGraph

/// Process-wide pointer to the active graph and flush hook for the current window.
///
/// The MVP runs a single window on the main thread, so a global is sufficient. A future
/// multi-window version will thread this through the view-graph context instead.
@MainActor
public enum GraphContext {
    static var current: Graph?
    /// The retained, identity-keyed view graph: per-composite memoized body rules + persistent `@State`.
    /// Installed by the runtime per app graph (and a throwaway one per secondary-window snapshot).
    static var viewGraph: ViewGraph?
    /// Performs one re-render: re-pulls the render tree and applies the minimal native mutations.
    static var flush: (@MainActor () -> Void)?
    /// Defers work onto the toolkit's main loop (installed by the runtime, wrapping
    /// `AppToolkit.scheduleOnMainThread`). All flushes route through this so they run on the loop —
    /// after the current native event finishes — rather than reentrantly inside an event handler.
    static var scheduleOnMain: (@MainActor (@escaping @MainActor () -> Void) -> Void)?
    /// Invalidates the root render rule so the next flush re-evaluates the tree. Needed for
    /// `@Observable` changes (which don't dirty a graph source); harmless for `@State`.
    static var invalidateRoot: (@MainActor () -> Void)?

    private static var flushScheduled = false
    /// Number of flushes performed. Tests read this to assert per-event coalescing.
    static private(set) var flushCount = 0

    static func requireCurrent() -> Graph {
        guard let graph = current else {
            fatalError("No active HopUI graph; @State accessed outside of a running app")
        }
        return graph
    }

    /// Request a re-render. **Coalesced**: at most one flush runs per main-loop turn, so several
    /// `@State` and/or `@Observable` mutations within a single event produce ONE re-render, and that
    /// render runs on the loop (not reentrantly inside the native event handler that triggered it).
    /// This unifies the `@State` and `@Observable` paths — the Observation runtime reports in `willSet`
    /// (before commit), and deferring everything the same way lets every flush read committed values.
    static func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let schedule = scheduleOnMain ?? { work in work() }  // no loop installed (defensive) → run now
        schedule {
            flushScheduled = false  // reset first, so a mutation made during the flush schedules the next turn
            invalidateRoot?()
            flushCount += 1
            flush?()
        }
    }

    /// Reset the per-app flush-coalescing state when a new app graph is installed. Without this, a prior
    /// run's pending (undrained) flush would leave `flushScheduled == true` and suppress the new app's
    /// first scheduled flush. Production has one app for the process lifetime, but tests install many.
    static func resetForNewApp() {
        flushScheduled = false
        flushCount = 0
        AppStorageRegistry.reset()  // its cached key sources belong to the graph being replaced
    }

    /// Called from the Observation `onChange` handler. Kept argument-free so the (`@Sendable`)
    /// handler captures nothing.
    static func requestObservationFlush() { scheduleFlush() }
}

/// Source-of-truth state owned by a view, backed by a source node in the ``Graph``.
///
/// The value lives in a reference-typed `Box` stored *outside* the `View` struct (which is
/// recreated on every re-evaluation. The box lazily
/// creates its graph source on first access; reads register a dependency on the current body and
/// writes invalidate it and schedule a flush.
@propertyWrapper
public struct State<Value> {
    // `nonisolated`: this is isolation-agnostic backing storage (like HopGraph), only ever touched on the
    // main run loop. Marking it nonisolated also sidesteps a Swift 6.3 SILGen crash synthesizing the
    // *isolating* `deinit` for a generic class nested in a generic type under `-default-isolation MainActor`
    // (assertion in emitIsolatingDestructor); a nonisolated class gets an ordinary deinit. Harmless on 6.2.
    nonisolated final class Box {
        var source: Attribute<Value>?
        let initial: Value
        /// Set by ``StateStore/bind(_:identity:slot:)`` on a *recreated* view: this (fresh) box forwards
        /// to the persistent box's graph source, so the value survives re-renders. The persistent box is
        /// retained by the store; the fresh box never makes its own source while delegating.
        var delegate: Box?
        init(_ initial: Value) { self.initial = initial }

        func source(in graph: Graph) -> Attribute<Value> {
            if let delegate { return delegate.source(in: graph) }
            if let source { return source }
            let created = graph.makeSource(initial)
            source = created
            return created
        }
    }

    private let box: Box

    public init(wrappedValue: Value) { box = Box(wrappedValue) }
    public init(initialValue: Value) { box = Box(initialValue) }

    public var wrappedValue: Value {
        get {
            let graph = GraphContext.requireCurrent()
            return graph.read(box.source(in: graph))
        }
        nonmutating set {
            let graph = GraphContext.requireCurrent()
            graph.setValue(newValue, for: box.source(in: graph))
            GraphContext.scheduleFlush()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
    }
}

/// A view property whose storage the framework persists by *view identity* across re-renders (mirroring
/// SwiftUI's `DynamicProperty`). The evaluator links each one to its persistent slot before the view's
/// `body` runs. `@State` conforms; `@Binding`/`@Environment` don't (they reference storage owned elsewhere).
@MainActor
protocol _DynamicProperty {
    func _link(slot: Int, into node: CompositeNode)
}

extension State: _DynamicProperty {
    // Reached via reflection on a value copy of the view — but `box` is a reference shared with the real
    // view, so binding its delegate here is seen by the view's `body`.
    func _link(slot: Int, into node: CompositeNode) {
        node.bind(box, slot: slot)
    }
}

/// A two-way reference to a value owned elsewhere. Mirrors SwiftUI's `Binding`.
@propertyWrapper
public struct Binding<Value> {
    public let get: @MainActor () -> Value
    public let set: @MainActor (Value) -> Void

    public init(get: @escaping @MainActor () -> Value, set: @escaping @MainActor (Value) -> Void) {
        self.get = get
        self.set = set
    }

    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }

    public var projectedValue: Binding<Value> { self }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }
}
