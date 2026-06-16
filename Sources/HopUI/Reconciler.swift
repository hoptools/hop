// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// Diffs successive render trees against the retained native widget tree, applying the minimal set
/// of toolkit operations.
///
/// Children are matched by identity, not position: a child whose id survives a re-render keeps its
/// widget (and its native state) even if it moved, was inserted before, or had a sibling removed.
/// New ids are realized in place; dropped ids are removed and their subtree torn down. This is what
/// makes `ForEach` reorder/insert/delete and `if`/`else` branch switching behave like SwiftUI.
final class Reconciler<Toolkit: RenderToolkit> {
    private let toolkit: Toolkit
    private var handles: [String: Toolkit.Handle] = [:]
    private var previous: RenderNode?
    /// Phase 3 incremental layout: cache each node's measured size by (subtree revision, proposal), so an
    /// unchanged subtree is not re-measured through the toolkit (the expensive native step) every flush.
    /// Safe by the same invariant as the reconcile skip — a stable revision means identical content.
    private var measureCache: [String: (revision: Int, width: Double?, height: Double?, size: CGSize)] = [:]

    init(toolkit: Toolkit) { self.toolkit = toolkit }

    // An explicit nonisolated deinit avoids synthesizing an *isolating* destructor for this generic
    // MainActor class, which crashes Swift 6.3's SILGen (assertion in emitIsolatingDestructor). Tearing
    // down the handle map needs no main-actor hop (it only releases references). Gated to 6.3+ so the
    // synthesized deinit (which compiles fine on the 6.2 toolchain the repo's CI uses) is left untouched.
    #if compiler(>=6.3)
    nonisolated deinit {}
    #endif

    /// Create the widget tree for `root` and insert it into `container`.
    func mount(_ root: RenderNode, into container: Toolkit.Handle) {
        let handle = realize(root)
        toolkit.insert(handle, into: container, at: 0)
        previous = root
    }

    /// Diff `new` against the previously rendered tree and apply changes.
    func update(_ new: RenderNode) {
        guard let old = previous else { return }
        reconcile(old: old, new: new)
        previous = new
    }

    /// Run HopUI's layout engine over the current tree, sizing/positioning every widget within `rect`
    /// (the window's content area). Leaves are measured through the toolkit; frames are applied via
    /// `setFrame`. Call after `mount`/`update` and whenever the window resizes.
    func layout(in rect: CGRect) {
        guard let root = previous else { return }
        let engine = LayoutEngine(
            measureLeaf: { [self] node, proposal in
                guard let handle = handles[node.id] else { return .zero }
                if node.subtreeRevision != 0, let cached = measureCache[node.id],
                   cached.revision == node.subtreeRevision,
                   cached.width == proposal.width, cached.height == proposal.height {
                    return cached.size   // identical content + same proposal → reuse, skip native measure
                }
                let size = node.component.map { toolkit.measureComponent(handle, $0, proposal) }
                    ?? toolkit.measure(handle, proposal)
                if node.subtreeRevision != 0 {
                    measureCache[node.id] = (node.subtreeRevision, proposal.width, proposal.height, size)
                }
                return size
            },
            setFrame: { [self] node, frame in if let h = handles[node.id] { toolkit.setFrame(h, frame) } },
            sizeOf: { [self] node in handles[node.id].map { toolkit.sizeOf($0) } ?? .zero })
        engine.place(root, rect)
    }

    private func realize(_ node: RenderNode) -> Toolkit.Handle {
        let handle: Toolkit.Handle
        if let component = node.component {
            // Open component path: the renderer (or self-hosted code) creates AND configures the widget.
            handle = toolkit.realize(component)
            // Cross-cutting modifier patch (e.g. .accessibilityLabel) attaches to the node, not the
            // component. Apply it only when a modifier actually set something, so a default (empty) patch
            // doesn't re-run a widget configure that would reset component-owned state (e.g. progress).
            if node.patch != WidgetPatch() { toolkit.configure(handle, node.patch) }
        } else {
            handle = toolkit.makeWidget(node.kind)
            toolkit.configure(handle, node.patch)
            toolkit.setAction(handle, node.action)
            toolkit.setTextHandler(handle, node.onChange)
            toolkit.setValueHandler(handle, node.onChangeDouble)
            toolkit.setBoolHandler(handle, node.onChangeBool)
            if let list = node.list { toolkit.configureList(handle, list) }
            if let shape = node.shape { toolkit.configureShape(handle, shape) }
            if let menu = node.menu { toolkit.configureMenu(handle, menu) }
            if let picker = node.picker { toolkit.configurePicker(handle, picker) }
            if let datePicker = node.datePicker { toolkit.configureDatePicker(handle, datePicker) }
            if let colorPicker = node.colorPicker { toolkit.configureColorPicker(handle, colorPicker) }
            if let outline = node.outline { toolkit.configureOutline(handle, outline) }
            if let image = node.image { toolkit.configureImage(handle, image) }
            toolkit.setScrollHandler(handle, node.onScroll)
        }
        // Cross-cutting presentation attachments apply to any widget (migrated or legacy).
        if let fileImporter = node.fileImporter { toolkit.configureFileImporter(handle, fileImporter) }
        if let fileExporter = node.fileExporter { toolkit.configureFileExporter(handle, fileExporter) }
        handles[node.id] = handle
        for (index, child) in node.children.enumerated() {
            toolkit.insert(realize(child), into: handle, at: index)
        }
        // A native composite (tab widget) builds itself from the now-inserted children, so notify last.
        if let component = node.component { toolkit.didInsertChildren(handle, component) }
        else if let tabs = node.tabs { toolkit.configureTabs(handle, tabs) }
        return handle
    }

    private func reconcile(old: RenderNode, new: RenderNode) {
        guard old.reuseSignature == new.reuseSignature, let handle = handles[new.id] else { return }
        // Incremental skip (Phase 2): a nonzero revision that matches the previous one means the resolve
        // pass returned the *exact same* cached nodes — the subtree is byte-identical, so its widgets are
        // already correct and we touch nothing. This is safe by construction: the revision is preserved
        // only for verbatim-reused subtrees (see `ViewGraph.resolveComposite`).
        if new.subtreeRevision != 0 && new.subtreeRevision == old.subtreeRevision { return }
        if let component = new.component {
            toolkit.updateComponent(handle, component)
            if new.patch != WidgetPatch() { toolkit.configure(handle, new.patch) }   // cross-cutting modifier patch
        } else {
            if new.patch != old.patch {
                toolkit.configure(handle, new.patch)
            }
            toolkit.setAction(handle, new.action)
            toolkit.setTextHandler(handle, new.onChange)
            toolkit.setValueHandler(handle, new.onChangeDouble)
            toolkit.setBoolHandler(handle, new.onChangeBool)
            if let list = new.list { toolkit.configureList(handle, list) }
            if let shape = new.shape { toolkit.configureShape(handle, shape) }
            if let menu = new.menu { toolkit.configureMenu(handle, menu) }
            if let picker = new.picker { toolkit.configurePicker(handle, picker) }
            if let datePicker = new.datePicker { toolkit.configureDatePicker(handle, datePicker) }
            if let colorPicker = new.colorPicker { toolkit.configureColorPicker(handle, colorPicker) }
            if let outline = new.outline { toolkit.configureOutline(handle, outline) }
            if let image = new.image { toolkit.configureImage(handle, image) }
            toolkit.setScrollHandler(handle, new.onScroll)
        }
        if let fileImporter = new.fileImporter { toolkit.configureFileImporter(handle, fileImporter) }
        if let fileExporter = new.fileExporter { toolkit.configureFileExporter(handle, fileExporter) }
        reconcileChildren(parent: handle, old: old.children, new: new.children)
        // Notify a native composite after its children are reconciled (tab titles/selection track them).
        if let component = new.component { toolkit.didInsertChildren(handle, component) }
        else if let tabs = new.tabs { toolkit.configureTabs(handle, tabs) }
    }

    /// Keyed child diff: match by ``RenderNode/id``, reuse matched handles (preserving native state)
    /// even across reordering, realize brand-new ids in place, and remove + tear down dropped ids.
    /// A `move` is emitted only for children whose position actually changed, so a pure prop change,
    /// a pure append, or a single mid-list insert/delete costs zero spurious moves.
    private func reconcileChildren(parent: Toolkit.Handle, old: [RenderNode], new: [RenderNode]) {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // A new child reuses an old one when they share id AND reuse-signature (kind, or a migrated
        // component's widgetKey). A signature change at the same id — e.g. a Picker whose style switched
        // its native widget — is a remove + realize, since the underlying widget type differs.
        func reusable(_ node: RenderNode) -> Bool {
            guard let prior = oldByID[node.id] else { return false }
            return prior.reuseSignature == node.reuseSignature && handles[node.id] != nil
        }
        let keptIDs = Set(new.filter(reusable).map { $0.id })

        // 1. Remove old children that aren't kept (id gone, or kind changed at the same id).
        for child in old where !keptIDs.contains(child.id) {
            if let handle = handles[child.id] { toolkit.remove(handle, from: parent) }
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
                    toolkit.move(handle, in: parent, to: index)
                    currentOrder.remove(at: currentIndex)
                    currentOrder.insert(child.id, at: index)
                }
            } else {
                let handle = realize(child)
                toolkit.insert(handle, into: parent, at: index)
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
