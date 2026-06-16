// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import HopGraph
import Observation

/// Test instrumentation: counts how many times each composite's `body` is evaluated, by view type and by
/// identity. Disabled by default (one branch in the body rule when off); tests enable it to assert that a
/// change re-runs ONLY the bodies it must (minimal over-invalidation) and re-runs the ones it should (no
/// under-invalidation). Not for production use.
@MainActor
enum BodyEvalTracker {
    static var enabled = false
    private(set) static var byType: [String: Int] = [:]
    private(set) static var byID: [String: Int] = [:]

    static func reset() { byType = [:]; byID = [:] }
    static func count(type: String) -> Int { byType[type] ?? 0 }
    static func count(id: String) -> Int { byID[id] ?? 0 }
    /// Total bodies evaluated since the last reset.
    static var total: Int { byType.values.reduce(0, +) }

    static func record(type: String, id: String) {
        guard enabled else { return }
        byType[type, default: 0] += 1
        byID[id, default: 0] += 1
    }
}

/// The retained, identity-keyed view graph — the heart of HopUI's fine-grained reactivity.
///
/// Every composite (user) view position owns a persistent ``CompositeNode`` whose `body` is its own
/// graph rule. `evaluate`'s composite branch does get-or-create + prop-diff + `read(node.body)` instead
/// of inlining `evaluate(view.body)`. Because each body is a memoized rule, only the composites whose
/// inputs actually changed re-run — their `@State` (graph sources), the environment they read (a graph
/// attribute), their observed `@Observable` properties, or their incoming props (prop-diff). Everything
/// else stays memoized. This mirrors SwiftUI: the body is the unit of recomputation, with no view
/// re-running because an unrelated sibling or a descendant changed.
///
/// It also absorbs the former `StateStore`: a node holds its own `@State` boxes, and the registry
/// mark-and-sweeps identities each pass so a removed view drops its state (and re-adding starts fresh).
///
/// See `project_hopui_finegrained_reactivity`.
@MainActor
final class ViewGraph {
    let graph: Graph

    /// The base environment for the whole tree (openWindow etc.). The runtime seeds it; `.environment`
    /// modifiers derive child attributes from it.
    let baseEnvironment: Attribute<EnvironmentValues>

    /// identity → retained composite node.
    private var composites: [String: CompositeNode] = [:]
    /// `.environment`/`.font`/`.foregroundStyle` modifier identity → its derived environment source.
    /// Never swept (reused by structural id if the subtree reappears); orphaned sources are a minor leak.
    private var derivedEnvs: [String: Attribute<EnvironmentValues>] = [:]
    /// The composite whose body is currently evaluating, so `composite(for:)` can register direct-child
    /// links — the basis for incremental teardown (a global per-pass sweep can't work: a *memoized*
    /// subtree isn't re-walked, so it wouldn't be marked visited and would be wrongly evicted).
    var evaluating: CompositeNode?

    /// Per view-type: does it declare any dynamic properties (`@State`)? Caches the reflection result so
    /// the many state-free view types are reflected at most once, then skipped.
    private var hasDynamicProps: [ObjectIdentifier: Bool] = [:]
    /// Per field-type: is it a function (closure) type? Closures are skipped in prop-diff.
    private var isFunctionType: [ObjectIdentifier: Bool] = [:]

    /// Monotonic source of subtree revisions. A resolved node gets a fresh revision whenever it is rebuilt
    /// (its producing composite re-ran or a descendant changed); an unchanged subtree reuses the exact
    /// cached nodes, so its revisions are preserved. Thus `a.subtreeRevision == b.subtreeRevision`
    /// across flushes ⟺ the subtrees are byte-identical — the invariant that makes incremental reconcile
    /// and layout SAFE (skipping an identical subtree can never cause stale UI).
    private var revisionSeq = 0
    func nextRevision() -> Int { revisionSeq += 1; return revisionSeq }

    init(graph: Graph) {
        self.graph = graph
        self.baseEnvironment = graph.makeSource(EnvironmentValues())
    }

    // MARK: Incremental teardown

    /// Remove a composite and its whole subtree from the registry — a view that left the tree (an `if`
    /// arm hidden, a `ForEach` element dropped). Its `@State` is discarded, so re-adding starts fresh,
    /// like SwiftUI. Called when a re-running parent's direct-child set no longer contains it. The
    /// dropped composites' graph rules/sources become orphans (never read again); reclaiming graph nodes
    /// is a later refinement.
    func remove(_ id: String) {
        guard let node = composites.removeValue(forKey: id) else { return }
        for child in node.children { remove(child) }
    }

    // MARK: Composites

    /// Get-or-create the composite node for `view` at `id`, registering it as a direct child of the
    /// currently-evaluating composite and pushing its current props (prop-diff) so its `body` rule is
    /// invalidated only when the props actually changed. Callers then `read(node.body)`.
    func composite(for view: any View, id: String, context: RenderContext) -> CompositeNode {
        evaluating?.children.insert(id)
        if let node = composites[id] {
            // Prop-diff: re-run the body only if the incoming view value differs (excluding @State/closures).
            if !viewsEqual(view, node.currentView) {
                node.currentView = view
                graph.invalidate(node.body.base, markDirty: false)  // mid-pass: this flush will re-read it
            }
            return node
        }
        let node = CompositeNode(id: id, currentView: view,
                                 environment: EnvironmentStore.currentAttr ?? baseEnvironment,
                                 context: context, owner: self)
        // The body rule captures the node weakly: the graph node outlives a swept composite, but a swept
        // node is never read again, so returning [] is safe.
        node.body = graph.makeRule { [weak node] _ in
            MainActor.assumeIsolated { node?.evaluateBody() ?? [] }
        }
        composites[id] = node
        return node
    }

    /// Reflect a view's stored properties in declaration order and bind each `@State` (and any other
    /// ``_DynamicProperty``) to its persistent slot on `node`, so values survive the view struct being
    /// recreated. State-free types are reflected once then skipped.
    func linkDynamicProperties(of view: any View, into node: CompositeNode) {
        let typeID = ObjectIdentifier(type(of: view))
        if hasDynamicProps[typeID] == false { return }
        var slot = 0
        for child in Mirror(reflecting: view).children {
            if let dynamic = child.value as? _DynamicProperty {
                dynamic._link(slot: slot, into: node)
                slot += 1
            }
        }
        hasDynamicProps[typeID] = slot > 0
    }

    // MARK: Environment derivation

    /// Get-or-create the derived environment source for an environment-modifying view at `id` (an
    /// `.environment`/`.font`/`.foregroundStyle` modifier, or a `NavigationStack` injecting its push
    /// action). Reads the parent environment (recording a dependency on the enclosing body, so it
    /// re-derives when the parent env changes) and applies `mutate`; pushes the result with
    /// `setValueIfChanged` so descendants re-run only when the derived environment actually changed.
    func derivedEnvironment(for id: String, _ mutate: (inout EnvironmentValues) -> Void) -> Attribute<EnvironmentValues> {
        let parent = EnvironmentStore.currentAttr ?? baseEnvironment
        var derived = graph.read(parent)
        mutate(&derived)
        if let existing = derivedEnvs[id] {
            graph.setValueIfChanged(derived, for: existing,
                                    equals: { $0.sameEnvironment(as: $1) }, markDirty: false)
            return existing
        }
        let source = graph.makeSource(derived)
        derivedEnvs[id] = source
        return source
    }

    // MARK: Prop-diff (view value equality)

    /// Whether two view values are equal for memoization purposes: a user `Equatable` view uses its own
    /// `==` (matching SwiftUI's `EquatableView` fast path); otherwise stored properties are compared
    /// field-wise — skipping `@State` (fresh boxes each pass, persisted separately) and closures
    /// (recreated each pass but refreshed via re-run when their captured state/props/env change), and
    /// treating any non-`Equatable` value property conservatively as "changed" (so it re-runs).
    func viewsEqual(_ a: any View, _ b: any View) -> Bool {
        if let ea = a as? any Equatable { return Self.areEqual(ea, b) }
        return fieldsEqual(a, b)
    }

    private func fieldsEqual(_ a: any View, _ b: any View) -> Bool {
        let ma = Mirror(reflecting: a)
        let mb = Mirror(reflecting: b)
        guard ma.subjectType == mb.subjectType else { return false }
        let bIterator = mb.children.makeIterator()
        for ca in ma.children {
            guard let cb = bIterator.next() else { return false }
            if fieldChanged(ca.value, cb.value) { return false }
        }
        return true
    }

    /// Whether a single stored-property pair forces a re-run.
    private func fieldChanged(_ a: Any, _ b: Any) -> Bool {
        if a is _DynamicProperty { return false }       // @State — handled by identity-keyed storage
        if let ea = a as? any Equatable { return !Self.areEqual(ea, b) }
        if isFunction(a) { return false }               // closure — behavior refreshed via re-run
        return true                                     // non-Equatable value (e.g. a child View) → re-run
    }

    /// Open the existential to compare two `Equatable` values of the same dynamic type.
    private static func areEqual(_ a: any Equatable, _ b: Any) -> Bool {
        func check<T: Equatable>(_ x: T) -> Bool { (b as? T) == x }
        return check(a)
    }

    private func isFunction(_ value: Any) -> Bool {
        let typeID = ObjectIdentifier(type(of: value))
        if let known = isFunctionType[typeID] { return known }
        // Function-type names contain "->"; this is the only reliable reflection-based detector.
        let result = _typeName(type(of: value), qualified: false).contains("->")
        isFunctionType[typeID] = result
        return result
    }
}

extension ViewGraph {
    /// Expand composite references into a concrete render tree by reading each referenced `body` rule, and
    /// stamp every node with a `subtreeRevision` (so reconcile/layout can skip byte-identical subtrees).
    ///
    /// Reading a memoized body returns its cached subtree without re-running it, so this re-runs ONLY the
    /// composite bodies that were invalidated. A composite whose body did NOT re-run AND none of whose
    /// descendant composites changed returns its *cached resolved subtree verbatim* — preserving its
    /// revisions, which is the signal the reconciler/layout use to skip it. The result contains no
    /// references (what the reconciler and layout engine consume).
    ///
    /// `tracking` accumulates whether anything changed, propagating up so a parent rebuilds (with fresh
    /// revisions) exactly when some composite within it re-ran.
    func resolve(_ nodes: [RenderNode], _ changed: inout Bool) -> [RenderNode] {
        var out: [RenderNode] = []
        out.reserveCapacity(nodes.count)
        for node in nodes {
            if let composite = node.compositeRef {
                let (sub, subChanged) = resolveComposite(composite, reference: node)
                if subChanged { changed = true }
                out += sub
            } else {
                var n = node
                var childChanged = false
                if !node.children.isEmpty { n.children = resolve(node.children, &childChanged) }
                // An inline node belongs to its producing composite's body; that body is rebuilt only when
                // the composite re-ran, in which case we're already on a `changed` path and assign a fresh
                // revision. (When nothing changed we never reach here — the composite returns its cache.)
                n.subtreeRevision = nextRevision()
                if childChanged { changed = true }
                out.append(n)
            }
        }
        return out
    }

    /// Resolve a single composite reference, reusing its cached resolved subtree when neither its body nor
    /// any descendant changed (so its revisions — and the reconcile/layout skip — are preserved).
    private func resolveComposite(_ composite: CompositeNode, reference: RenderNode) -> (out: [RenderNode], changed: Bool) {
        let body = graph.read(composite.body)   // recomputes if invalidated → evaluateBody bumps `generation`
        let bodyChanged = composite.generation != composite.resolveGeneration
        var childrenChanged = false
        let resolvedBody = resolve(body, &childrenChanged)
        if !bodyChanged && !childrenChanged, let cached = composite.resolvedCache {
            return (cached, false)   // identical subtree → reuse verbatim (revisions preserved)
        }
        composite.resolveGeneration = composite.generation
        var out = resolvedBody
        // Transfer modifier state accumulated on the reference (.frame/.toolbar/.tag/…) onto the composite's
        // first rendered node, so wrapping a composite behaves like wrapping a primitive. Re-stamp it: the
        // wrapper changed the node, so its previous revision no longer describes it.
        if !out.isEmpty, reference.hasWrapperState {
            out[0].applyWrapperState(from: reference)
            out[0].subtreeRevision = nextRevision()
        }
        composite.resolvedCache = out
        return (out, true)
    }
}

/// Top-level resolve for a flush: expand references from `nodes` into a concrete, revision-stamped tree.
@MainActor
func resolveRenderTree(_ nodes: [RenderNode], _ graph: Graph) -> [RenderNode] {
    guard let viewGraph = GraphContext.viewGraph else { return nodes }
    var changed = false
    return viewGraph.resolve(nodes, &changed)
}

/// Evaluate a view and resolve its composite references in one step — for primitives that must inspect
/// or restructure their content's concrete nodes during evaluation. (Reading the referenced bodies here
/// records dependencies on the enclosing body, so it re-runs when the inspected content changes — the
/// intended, bounded coupling for content-collecting containers.)
@MainActor
func evaluateResolved(_ view: any View, _ context: RenderContext) -> [RenderNode] {
    let nodes = evaluate(view, context)
    guard let graph = GraphContext.current else { return nodes }
    return resolveRenderTree(nodes, graph)
}

/// One retained composite (user) view position. Owns the view's `body` rule, its persistent `@State`
/// boxes, and the environment attribute it received. Recreated only when its identity first appears;
/// swept when its identity leaves the tree.
@MainActor
final class CompositeNode {
    let id: String
    let context: RenderContext
    /// The environment attribute this view receives (captured at its position; stable for the identity).
    let environment: Attribute<EnvironmentValues>
    weak var owner: ViewGraph?

    /// The current view value, refreshed by prop-diff. Read (plainly) by the body rule; changing it goes
    /// with `graph.invalidate(body)`.
    var currentView: any View
    /// This view's memoized body rule. Set immediately after init.
    var body: Attribute<[RenderNode]>!
    /// Direct child composite identities reached during the last body eval. Rebuilt each eval so a child
    /// that disappears is detected and torn down (incremental sweep).
    var children: Set<String> = []
    /// Bumped each time `body` actually re-evaluates. The resolve pass compares it to `resolveGeneration`
    /// to know whether this composite's body changed since last flush (for the incremental skip).
    var generation = 0
    /// `generation` at the time `resolvedCache` was last built.
    var resolveGeneration = -1
    /// The composite's last fully-resolved subtree; reused verbatim (revisions preserved) when neither its
    /// body nor any descendant changed, which is how reconcile/layout skip an unchanged subtree.
    var resolvedCache: [RenderNode]?
    /// Persistent `@State` storage, one box per `@State` property in declaration order.
    private var stateBoxes: [AnyObject] = []

    init(id: String, currentView: any View, environment: Attribute<EnvironmentValues>,
         context: RenderContext, owner: ViewGraph) {
        self.id = id
        self.currentView = currentView
        self.environment = environment
        self.context = context
        self.owner = owner
    }

    /// Evaluate the view's body: bracket the environment so descendants/leaves read it through the graph,
    /// link `@State`, and track `@Observable` reads so the first subsequent mutation re-runs *this* body
    /// (and only this body) — fine-grained observation.
    func evaluateBody() -> [RenderNode] {
        guard let owner else { return [] }
        let savedEnv = EnvironmentStore.currentAttr
        let savedEvaluating = owner.evaluating
        EnvironmentStore.currentAttr = environment
        owner.evaluating = self
        let oldChildren = children
        children = []
        defer {
            EnvironmentStore.currentAttr = savedEnv
            owner.evaluating = savedEvaluating
            // Tear down child composites that were present last eval but not this one (state resets).
            for removed in oldChildren where !children.contains(removed) { owner.remove(removed) }
        }
        generation += 1   // mark this body as re-evaluated, so the resolve pass rebuilds this subtree
        owner.linkDynamicProperties(of: currentView, into: self)
        BodyEvalTracker.record(type: "\(type(of: currentView))", id: id)
        return withObservationTracking {
            evaluate(currentView.body, context.appending(0))
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let graph = GraphContext.current else { return }
                graph.invalidate(self.body.base, markDirty: true)
                GraphContext.scheduleFlush()
            }
        }
    }

    /// Bind a freshly-created `@State` box to its persistent slot. The first sighting of a slot adopts
    /// the box as persistent; later sightings point the fresh box's delegate at the persistent one, so
    /// reads/writes resolve to the persisted graph source.
    func bind<Value>(_ box: State<Value>.Box, slot: Int) {
        if slot < stateBoxes.count {
            if let persistent = stateBoxes[slot] as? State<Value>.Box {
                if persistent !== box { box.delegate = persistent }
                return
            }
            stateBoxes[slot] = box   // a different type now occupies this slot (rare) → reset
        } else {
            stateBoxes.append(box)   // first sighting → adopt as persistent
        }
    }
}
