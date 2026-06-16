// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// A demand-driven (pull-based) attribute graph, modeled on Apple's private AttributeGraph.
///
/// Nodes are either **sources** (mutable inputs, e.g. the backing for `@State`) or **rules**
/// (closures that derive a value from other attributes). Values are computed lazily on read and
/// memoized until invalidated. Dependency edges are *discovered dynamically* during evaluation:
/// while a rule runs, any attribute it reads becomes one of its inputs. Writing a source marks
/// everything transitively downstream as pending — without recomputing — and recomputation
/// happens on the next read (the "pull").
///
/// This MVP is single-threaded and intended to run on the UI thread; a future version will add
/// subgraphs (lifetime grouping), generation-tagged handles, and a frame-batched flush.
public final class Graph {
    enum NodeState { case valid, pending, computing }

    final class Node {
        /// The derivation closure; `nil` for source nodes.
        var rule: ((Graph) -> Any)?
        var value: Any?
        var state: NodeState
        /// Attributes this node read during its last evaluation (rebuilt every eval).
        var incoming: Set<Int> = []
        /// Attributes that depend on this node (used to propagate invalidation upward).
        var outgoing: Set<Int> = []

        init(rule: ((Graph) -> Any)?, value: Any?, state: NodeState) {
            self.rule = rule
            self.value = value
            self.state = state
        }
    }

    private var nodes: [Node] = []

    /// The attribute currently being evaluated, used for dynamic edge discovery. Any `read`
    /// performed while this is set records an edge from the read attribute to this one.
    private var current: Int?

    /// Source attributes written since the last ``clearDirty()``. The runtime checks this to
    /// decide whether a flush is needed.
    public private(set) var dirty: Set<Int> = []

    public init() {}

    public var hasDirty: Bool { !dirty.isEmpty }
    public func clearDirty() { dirty.removeAll() }

    /// Create a mutable source node seeded with `initial`. This is the backing for `@State`.
    public func makeSource<Value>(_ initial: Value) -> Attribute<Value> {
        nodes.append(Node(rule: nil, value: initial, state: .valid))
        return Attribute(base: AnyAttribute(index: nodes.count - 1))
    }

    /// Create a rule node that derives its value from other attributes it reads.
    public func makeRule<Value>(_ rule: @escaping (Graph) -> Value) -> Attribute<Value> {
        nodes.append(Node(rule: { g in rule(g) as Any }, value: nil, state: .pending))
        return Attribute(base: AnyAttribute(index: nodes.count - 1))
    }

    /// Read an attribute's value, computing it if necessary and recording a dependency edge if
    /// this read happens during another attribute's evaluation.
    public func read<Value>(_ attribute: Attribute<Value>) -> Value {
        let idx = attribute.base.index
        let node = nodes[idx]

        // Dynamic dependency discovery: whoever is mid-evaluation just read us → record the edge.
        if let reader = current, reader != idx {
            nodes[reader].incoming.insert(idx)
            node.outgoing.insert(reader)
        }

        switch node.state {
        case .valid:
            return node.value as! Value
        case .computing:
            fatalError("AttributeGraph cycle detected at attribute \(idx)")
        case .pending:
            return recompute(idx) as! Value
        }
    }

    private func recompute(_ idx: Int) -> Any {
        let node = nodes[idx]
        guard let rule = node.rule else {
            // A source should never be pending, but if it is just treat its stored value as valid.
            node.state = .valid
            return node.value as Any
        }

        // Edges are rebuilt fresh each evaluation, so dependencies can change run-to-run
        // (e.g. an `if` in a view body taking the other branch).
        for input in node.incoming { nodes[input].outgoing.remove(idx) }
        node.incoming.removeAll()

        let saved = current
        current = idx
        node.state = .computing
        defer { current = saved }

        let value = rule(self)
        node.value = value
        node.state = .valid
        return value
    }

    /// Write a new value into a source attribute and invalidate everything downstream.
    public func setValue<Value>(_ value: Value, for attribute: Attribute<Value>) {
        let idx = attribute.base.index
        nodes[idx].value = value
        invalidateConsumers(of: idx)
        dirty.insert(idx)
    }

    /// Write a value only if it differs from the current one (by `equals`), invalidating consumers
    /// just when it actually changed. This is the engine of fine-grained reactivity: a parent that
    /// re-runs and re-pushes the *same* derived input (a child's unchanged props, an unchanged derived
    /// environment) leaves the consumer memoized, so unchanged subtrees are not recomputed.
    ///
    /// `markDirty` controls whether the change is recorded in ``dirty`` (which the runtime polls to
    /// decide whether to flush). Pass `false` for writes performed *during* a flush (e.g. prop-diff
    /// pushes while evaluating), so they propagate this pass without scheduling a spurious extra flush.
    /// Returns whether the value changed.
    @discardableResult
    public func setValueIfChanged<Value>(_ value: Value, for attribute: Attribute<Value>,
                                         equals: (Value, Value) -> Bool, markDirty: Bool = true) -> Bool {
        let idx = attribute.base.index
        let node = nodes[idx]
        if let old = node.value as? Value, equals(old, value) { return false }
        node.value = value
        invalidateConsumers(of: idx)
        if markDirty { dirty.insert(idx) }
        return true
    }

    /// Mark a rule attribute pending (so it recomputes on next read) and propagate invalidation to its
    /// consumers — without writing a value. Used to invalidate a composite's `body` rule when a
    /// non-graph input changed: its view props (prop-diff) or an observed `@Observable` property.
    ///
    /// `markDirty` records the change in ``dirty`` so the runtime flushes; pass `false` for
    /// invalidations performed *during* a flush (prop-diff), which this pass already handles.
    public func invalidate(_ attribute: AnyAttribute, markDirty: Bool = false) {
        let idx = attribute.index
        let node = nodes[idx]
        if node.state == .valid { node.state = .pending }
        invalidateConsumers(of: idx)
        if markDirty { dirty.insert(idx) }
    }

    /// Mark all transitive consumers of `idx` as pending. Does not recompute — that happens on
    /// the next read.
    private func invalidateConsumers(of idx: Int) {
        var stack = Array(nodes[idx].outgoing)
        while let consumer = stack.popLast() {
            let node = nodes[consumer]
            if node.state == .valid {
                node.state = .pending
                stack.append(contentsOf: node.outgoing)
            }
        }
    }

    // MARK: Introspection (used by tests to assert minimal recompute)

    /// Number of nodes currently allocated.
    public var nodeCount: Int { nodes.count }

    /// Whether the given attribute is currently memoized as valid.
    public func isValid(_ attribute: AnyAttribute) -> Bool {
        nodes[attribute.index].state == .valid
    }
}
