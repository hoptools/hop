// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// Diffs successive render trees against the retained native widget tree, applying the minimal set
/// of backend operations.
///
/// Children are matched by identity, not position: a child whose id survives a re-render keeps its
/// widget (and its native state) even if it moved, was inserted before, or had a sibling removed.
/// New ids are realized in place; dropped ids are removed and their subtree torn down. This is what
/// makes `ForEach` reorder/insert/delete and `if`/`else` branch switching behave like SwiftUI.
final class Reconciler<Backend: RenderBackend> {
    private let backend: Backend
    private var handles: [String: Backend.Handle] = [:]
    private var previous: RenderNode?

    init(backend: Backend) { self.backend = backend }

    /// Create the widget tree for `root` and insert it into `container`.
    func mount(_ root: RenderNode, into container: Backend.Handle) {
        let handle = realize(root)
        backend.insert(handle, into: container, at: 0)
        previous = root
    }

    /// Diff `new` against the previously rendered tree and apply changes.
    func update(_ new: RenderNode) {
        guard let old = previous else { return }
        reconcile(old: old, new: new)
        previous = new
    }

    /// Run HopUI's layout engine over the current tree, sizing/positioning every widget within `rect`
    /// (the window's content area). Leaves are measured through the backend; frames are applied via
    /// `setFrame`. Call after `mount`/`update` and whenever the window resizes.
    func layout(in rect: CGRect) {
        guard let root = previous else { return }
        let engine = LayoutEngine(
            measureLeaf: { [self] node, proposal in handles[node.id].map { backend.measure($0, proposal) } ?? .zero },
            setFrame: { [self] node, frame in if let h = handles[node.id] { backend.setFrame(h, frame) } },
            sizeOf: { [self] node in handles[node.id].map { backend.sizeOf($0) } ?? .zero })
        engine.place(root, rect)
    }

    private func realize(_ node: RenderNode) -> Backend.Handle {
        let handle = backend.makeWidget(node.kind)
        backend.configure(handle, node.patch)
        backend.setAction(handle, node.action)
        backend.setTextHandler(handle, node.onChange)
        backend.setValueHandler(handle, node.onChangeDouble)
        backend.setBoolHandler(handle, node.onChangeBool)
        if let list = node.list { backend.configureList(handle, list) }
        if let shape = node.shape { backend.configureShape(handle, shape) }
        if let menu = node.menu { backend.configureMenu(handle, menu) }
        if let picker = node.picker { backend.configurePicker(handle, picker) }
        if let outline = node.outline { backend.configureOutline(handle, outline) }
        if let image = node.image { backend.configureImage(handle, image) }
        backend.setScrollHandler(handle, node.onScroll)
        handles[node.id] = handle
        for (index, child) in node.children.enumerated() {
            backend.insert(realize(child), into: handle, at: index)
        }
        // A native tab widget builds its tabs from the now-inserted page children, so configure last.
        if let tabs = node.tabs { backend.configureTabs(handle, tabs) }
        return handle
    }

    private func reconcile(old: RenderNode, new: RenderNode) {
        guard old.kind == new.kind, let handle = handles[new.id] else { return }
        if new.patch != old.patch {
            backend.configure(handle, new.patch)
        }
        backend.setAction(handle, new.action)
        backend.setTextHandler(handle, new.onChange)
        backend.setValueHandler(handle, new.onChangeDouble)
        backend.setBoolHandler(handle, new.onChangeBool)
        if let list = new.list { backend.configureList(handle, list) }
        if let shape = new.shape { backend.configureShape(handle, shape) }
        if let menu = new.menu { backend.configureMenu(handle, menu) }
        if let picker = new.picker { backend.configurePicker(handle, picker) }
        if let outline = new.outline { backend.configureOutline(handle, outline) }
        if let image = new.image { backend.configureImage(handle, image) }
        backend.setScrollHandler(handle, new.onScroll)
        reconcileChildren(parent: handle, old: old.children, new: new.children)
        // Configure tabs after the page children are reconciled (titles/selection track the live pages).
        if let tabs = new.tabs { backend.configureTabs(handle, tabs) }
    }

    /// Keyed child diff: match by ``RenderNode/id``, reuse matched handles (preserving native state)
    /// even across reordering, realize brand-new ids in place, and remove + tear down dropped ids.
    /// A `move` is emitted only for children whose position actually changed, so a pure prop change,
    /// a pure append, or a single mid-list insert/delete costs zero spurious moves.
    private func reconcileChildren(parent: Backend.Handle, old: [RenderNode], new: [RenderNode]) {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // A new child reuses an old one when they share id AND kind (a kind change at the same id is
        // treated as a remove + realize, since the widget type differs).
        func reusable(_ node: RenderNode) -> Bool {
            guard let prior = oldByID[node.id] else { return false }
            return prior.kind == node.kind && handles[node.id] != nil
        }
        let keptIDs = Set(new.filter(reusable).map { $0.id })

        // 1. Remove old children that aren't kept (id gone, or kind changed at the same id).
        for child in old where !keptIDs.contains(child.id) {
            if let handle = handles[child.id] { backend.remove(handle, from: parent) }
            teardown(child)
        }

        // 2. Bring the surviving handles into `new` order, realizing brand-new children in place.
        //    `currentOrder` tracks the parent's live child order so moves are emitted only when a
        //    reused child isn't already where it belongs (inserts shift it for free).
        var currentOrder = old.filter { keptIDs.contains($0.id) }.map { $0.id }
        for (index, child) in new.enumerated() {
            if reusable(child) {
                reconcile(old: oldByID[child.id]!, new: child)
                guard let handle = handles[child.id],
                      let currentIndex = currentOrder.firstIndex(of: child.id) else { continue }
                if currentIndex != index {
                    backend.move(handle, in: parent, to: index)
                    currentOrder.remove(at: currentIndex)
                    currentOrder.insert(child.id, at: index)
                }
            } else {
                let handle = realize(child)
                backend.insert(handle, into: parent, at: index)
                currentOrder.insert(child.id, at: Swift.min(index, currentOrder.count))
            }
        }
    }

    /// Recursively drop a removed subtree's handle entries. Removing the subtree's root from its
    /// parent detaches the whole subtree natively; this just clears our id → handle bookkeeping.
    private func teardown(_ node: RenderNode) {
        for child in node.children { teardown(child) }
        handles[node.id] = nil
    }
}
