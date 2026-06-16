// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// Persists `@State` storage by view identity so it survives re-renders of recreated view structs —
/// mirroring SwiftUI, where `@State` is keyed to a view's structural identity, not its (constantly
/// recreated) struct instance.
///
/// Each view position (its ``RenderContext/id``) owns one persistent ``State/Box`` per `@State` property,
/// in declaration order. During a render pass the evaluator links each freshly-created box to its
/// persistent slot (via ``bind(_:identity:slot:)``); identities not visited in a pass are swept, so a
/// view that's removed from the tree loses its state and starts fresh if re-added — exactly like SwiftUI.
@MainActor
final class StateStore {
    /// identity → persistent boxes (one per `@State` property slot, in declaration order). Boxes are
    /// type-erased; the same identity+slot always carries the same concrete `State<Value>.Box` type
    /// (a position's view type is structurally stable), so the cast in `bind` succeeds.
    private var slots: [String: [AnyObject]] = [:]
    /// Identities that own state and were visited during the current render pass (drives the sweep).
    private var visited: Set<String> = []
    /// Per view-type: does it declare any dynamic properties? Caches the reflection result so the many
    /// view types with no `@State` are reflected at most once, then skipped.
    private var hasDynamicProps: [ObjectIdentifier: Bool] = [:]

    /// Begin a render pass: clear the visited set so the post-pass sweep can detect removed views.
    func beginPass() { visited.removeAll(keepingCapacity: true) }

    /// End a render pass: drop state for identities not visited (a removed view loses its `@State`).
    func endPassAndSweep() {
        if visited.count == slots.count { return }   // nothing removed (visited ⊆ slots) — fast path
        slots = slots.filter { visited.contains($0.key) }
    }

    /// Cached "does this view type declare dynamic properties?" — `nil` = unknown (reflect to find out).
    func dynamicPropsKnown(_ type: ObjectIdentifier) -> Bool? { hasDynamicProps[type] }
    func recordDynamicProps(_ type: ObjectIdentifier, _ has: Bool) { hasDynamicProps[type] = has }

    /// Link a freshly-created `@State` box to its persistent slot for `identity`. The first time a slot is
    /// seen, this box becomes the persistent one; afterwards the fresh box is pointed at the persistent
    /// box's graph source (via its delegate) so reads and writes resolve to the persisted value.
    func bind<Value>(_ box: State<Value>.Box, identity: String, slot: Int) {
        visited.insert(identity)
        var boxes = slots[identity, default: []]
        if slot < boxes.count {
            if let persistent = boxes[slot] as? State<Value>.Box {
                if persistent !== box { box.delegate = persistent }   // re-render: delegate to the persistent box
                return                                                 // (persistent === box: the retained root view)
            }
            boxes[slot] = box   // a different type now occupies this slot (rare) → reset to the fresh box
        } else {
            boxes.append(box)   // first time we see this slot → adopt the fresh box as the persistent one
        }
        slots[identity] = boxes
    }
}
