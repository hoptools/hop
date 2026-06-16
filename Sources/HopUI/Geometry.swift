// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import HopGraph

// GeometryReader: a container that hands its content closure the size it was offered, so content can
// react to the available geometry. Because HopUI lays out in a pass *after* the view tree is built, the
// size flows back through a graph source: the engine reports the laid-out size via the node's
// `onGeometry`, which writes the source; that write invalidates the render rule, so the next flush
// re-evaluates the content with the real size. It converges in one extra pass and only re-renders when
// the size actually changes.

/// Geometry information passed to a ``GeometryReader``'s content. Mirrors SwiftUI's `GeometryProxy`
/// (size only, for the MVP).
public struct GeometryProxy: Sendable {
    public let size: CGSize
    public init(size: CGSize) { self.size = size }
    /// The reader's bounds in the requested coordinate space. The MVP reports a local-origin rect.
    public func frame(in coordinateSpace: CoordinateSpace) -> CGRect { CGRect(origin: .zero, size: size) }
}

/// A coordinate space for `GeometryProxy.frame(in:)`. Mirrors SwiftUI's `CoordinateSpace`.
public enum CoordinateSpace: Sendable {
    case local
    case global
    case named(String)
}

/// A container that sizes itself to the space offered by its parent and exposes that size to its
/// content via a ``GeometryProxy``. Mirrors SwiftUI's `GeometryReader`.
public struct GeometryReader<Content: View>: View, PrimitiveView {
    let content: (GeometryProxy) -> Content
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) { self.content = content }

    public typealias Body = Never
    public var body: Never { fatalError("GeometryReader has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let graph = GraphContext.requireCurrent()
        // A per-identity source holds the last laid-out size; reading it here makes the render rule
        // depend on it, so the engine's size feedback re-evaluates this content.
        let source = IdentitySourceStore.sizeSource(context.id, graph)
        let size = graph.read(source)

        let proxy = GeometryProxy(size: size)
        let childNodes = evaluate(content(proxy), context.appending(0))
        let child = childNodes.first ?? RenderNode(id: context.id + ".empty", kind: .vstack)

        return RenderNode(id: context.id, kind: .geometry, children: [child],
                          component: ContainerComponent(WidgetKey("geometry"), role: .geometry),
                          onGeometry: { newSize in
            // Only write (and re-render) when the size genuinely changes, so layout converges.
            if newSize != size {
                graph.setValue(newSize, for: source)
                GraphContext.scheduleFlush()
            }
        })
    }
}

/// Per-identity graph sources for layout-feedback values (e.g. ``GeometryReader`` sizes). Keyed by the
/// stable identity path so the source survives view re-evaluation, mirroring how `@State` survives via
/// its out-of-struct box. Reset when a new app graph is installed (see the runtime).
@MainActor
enum IdentitySourceStore {
    private static var sizeSources: [String: Attribute<CGSize>] = [:]
    private static var extentSources: [String: Attribute<Double>] = [:]
    private static var boolSources: [String: Attribute<Bool>] = [:]
    private static var intSources: [String: Attribute<Int>] = [:]

    static func sizeSource(_ id: String, _ graph: Graph) -> Attribute<CGSize> {
        if let existing = sizeSources[id] { return existing }
        let created = graph.makeSource(CGSize.zero)
        sizeSources[id] = created
        return created
    }

    /// A scalar source (e.g. a ``LazyVStack``'s refined uniform row extent).
    static func extentSource(_ id: String, _ graph: Graph) -> Attribute<Double> {
        if let existing = extentSources[id] { return existing }
        let created = graph.makeSource(0.0)
        extentSources[id] = created
        return created
    }

    /// A per-identity boolean source (e.g. a self-managed ``DisclosureGroup``'s expansion state).
    static func boolSource(_ id: String, _ graph: Graph, default initial: Bool = false) -> Attribute<Bool> {
        if let existing = boolSources[id] { return existing }
        let created = graph.makeSource(initial)
        boolSources[id] = created
        return created
    }

    /// A per-identity integer source (e.g. a self-managed ``TabView``'s selected tab index).
    static func intSource(_ id: String, _ graph: Graph, default initial: Int = 0) -> Attribute<Int> {
        if let existing = intSources[id] { return existing }
        let created = graph.makeSource(initial)
        intSources[id] = created
        return created
    }

    /// Clear the store so the next app run creates fresh sources against its new graph.
    static func reset() {
        sizeSources.removeAll()
        extentSources.removeAll()
        boolSources.removeAll()
        intSources.removeAll()
    }
}
