// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// An opaque, stable handle to a node in the ``Graph``.
///
/// Like Apple's private `AGAttribute`, this is just an integer index into the graph's node
/// table. It is cheap to copy, `Hashable`, and carries no reference to the value's type — the
/// typed ``Attribute`` wrapper layers that on top.
public struct AnyAttribute: Hashable {
    public let index: Int
    init(index: Int) { self.index = index }
}

/// A typed handle to a graph node producing `Value`.
///
/// Reading an attribute (``Graph/read(_:)``) lazily computes its value and, if performed while
/// another attribute is being evaluated, records a dependency edge — this dynamic edge discovery
/// is the defining property of an AttributeGraph.
public struct Attribute<Value> {
    public let base: AnyAttribute
    init(base: AnyAttribute) { self.base = base }
}
