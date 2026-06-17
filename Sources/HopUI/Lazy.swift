// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import HopGraph

// ScrollView + virtualizing LazyVStack/LazyHStack.
//
// A ScrollView establishes a "scroll context" (its viewport size + current scroll offset, both fed back
// through graph sources) while it evaluates its content. A LazyVStack/LazyHStack reads that context and
// — assuming a uniform row extent it refines via feedback — materializes ONLY the window of rows that
// intersect the visible range (plus a small buffer). The engine sizes the lazy stack to the FULL row
// count so the scrollbar is correct, and positions each materialized row at its absolute index offset.
// As the user scrolls, the offset source updates and the next render re-materializes a new window — so a
// list of 100,000 rows only ever builds ~a screenful of widgets.

/// The ambient scrolling context a ``LazyVStack``/``LazyHStack`` reads to compute its visible window.
/// Set by the enclosing ``ScrollView`` while it evaluates its content.
struct ScrollContext {
    var axis: Axis
    var viewport: CGSize
    var offset: CGSize
}

@MainActor
enum ScrollContextStore {
    static var current: ScrollContext?
    static func reset() { current = nil }
}

/// A scrollable viewport. Mirrors SwiftUI's `ScrollView`. The content is laid out at its natural size
/// along the scroll axis and scrolled within the viewport by the toolkit's native scroll container.
public struct ScrollView<Content: View>: View, PrimitiveView {
    let axis: Axis
    let content: () -> Content

    public init(_ axis: Axis = .vertical, @ViewBuilder content: @escaping () -> Content) {
        self.axis = axis
        self.content = content
    }

    public typealias Body = Never
    public var body: Never { fatalError("ScrollView has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let graph = GraphContext.requireCurrent()
        let viewportSource = IdentitySourceStore.sizeSource(context.id + "#viewport", graph)
        let offsetSource = IdentitySourceStore.sizeSource(context.id + "#offset", graph)
        let viewport = graph.read(viewportSource)
        let offset = graph.read(offsetSource)

        // Establish the scroll context for descendant lazy stacks while building content.
        let saved = ScrollContextStore.current
        ScrollContextStore.current = ScrollContext(axis: axis, viewport: viewport, offset: offset)
        defer { ScrollContextStore.current = saved }

        let childNodes = evaluate(content(), context.appending(0))
        let content = childNodes.first ?? RenderNode(id: context.id + ".empty", component: ContainerComponent.vstack())
        // Wrap the content in a top-leading container that becomes the scroll's document/viewport child.
        // The native scroll viewports (NSScrollView / GtkViewport) pin their child at origin (0,0), so any
        // outer `.padding()` on `content` (which would otherwise offset the document view and be dropped)
        // is preserved here as an inset *within* this wrapper.
        let child = RenderNode(id: context.id + ".content", component: ContainerComponent.zstack(alignment: .topLeading), children: [content],
                               layout: LayoutInfo(alignment: .topLeading))

        return RenderNode(id: context.id,
                          component: ContainerComponent(WidgetKey("scroll"), role: .scroll(axis: axis)),
                          children: [child],
                          layout: LayoutInfo(scrollAxis: axis),
                          onGeometry: { size in
                              if size != viewport { graph.setValue(size, for: viewportSource); GraphContext.scheduleFlush() }
                          },
                          onScroll: { newOffset in
                              if newOffset != offset { graph.setValue(newOffset, for: offsetSource); GraphContext.scheduleFlush() }
                          })
    }
}

/// The default row extent assumed before a lazy stack has measured its first row, and the default
/// viewport extent used when a lazy stack is not inside a ScrollView.
private let lazyDefaultRowExtent: Double = 44
private let lazyDefaultViewport: Double = 1000
/// Extra rows materialized beyond the visible range on each side, so scrolling doesn't flash empties.
private let lazyBufferRows = 4

/// A vertically-stacking container that materializes only the visible rows. Mirrors SwiftUI's
/// `LazyVStack`. Most efficient with a single `ForEach` child (the rows are then built on demand).
public struct LazyVStack<Content: View>: View, PrimitiveView {
    let alignment: HorizontalAlignment
    let spacing: Double?
    let content: () -> Content

    public init(alignment: HorizontalAlignment = .center, spacing: Double? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    public typealias Body = Never
    public var body: Never { fatalError("LazyVStack has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        makeLazyNode(context, axis: .vertical, spacing: spacing,
                     alignment: Alignment(horizontal: alignment, vertical: .center),
                     content: content)
    }
}

/// A horizontally-stacking container that materializes only the visible columns. Mirrors SwiftUI's
/// `LazyHStack`.
public struct LazyHStack<Content: View>: View, PrimitiveView {
    let alignment: VerticalAlignment
    let spacing: Double?
    let content: () -> Content

    public init(alignment: VerticalAlignment = .center, spacing: Double? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    public typealias Body = Never
    public var body: Never { fatalError("LazyHStack has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        makeLazyNode(context, axis: .horizontal, spacing: spacing,
                     alignment: Alignment(horizontal: .center, vertical: alignment),
                     content: content)
    }
}

/// Shared lazy-stack node construction: compute the visible window from the scroll context and a
/// (feedback-refined) uniform row extent, then materialize just those rows.
@MainActor
private func makeLazyNode<Content: View>(_ context: RenderContext, axis: Axis, spacing: Double?,
                                         alignment: Alignment, content: () -> Content) -> RenderNode {
    let spacing = spacing ?? hopDefaultSpacing
    let contentView = content()

    // Non-ForEach content can't be virtualized by index; fall back to an eager stack (still correct).
    guard let forEach = contentView as? AnyForEach else {
        let children = evaluate(contentView, context.appending(0))
        let fallback = axis == .vertical
            ? ContainerComponent.vstack(spacing: spacing, alignment: alignment)
            : ContainerComponent.hstack(spacing: spacing, alignment: alignment)
        return RenderNode(id: context.id, component: fallback, patch: WidgetPatch(spacing: spacing),
                          children: children, layout: LayoutInfo(alignment: alignment))
    }

    let count = forEach.forEachCount
    let graph = GraphContext.requireCurrent()
    let extentSource = IdentitySourceStore.extentSource(context.id, graph)
    let originSource = IdentitySourceStore.extentSource(context.id + "#origin", graph)
    let stored = graph.read(extentSource)
    let rowExtent = stored > 0 ? stored : lazyDefaultRowExtent
    let origin = graph.read(originSource)  // this stack's top within the enclosing scroll's content
    let stride = rowExtent + spacing

    // Visible range along the scroll axis, expressed relative to THIS stack's top (subtract its origin
    // within the scroll content, so a stack below other content still windows correctly).
    let vertical = axis == .vertical
    let ctx = ScrollContextStore.current
    let viewportExtent = ctx.map { vertical ? Double($0.viewport.height) : Double($0.viewport.width) } ?? 0
    let offsetExtent = ctx.map { vertical ? Double($0.offset.height) : Double($0.offset.width) } ?? 0
    let visibleMin = offsetExtent - origin
    let visibleMax = visibleMin + (viewportExtent > 0 ? viewportExtent : lazyDefaultViewport)

    var first = Int((visibleMin / stride).rounded(.down)) - lazyBufferRows
    var last = Int((visibleMax / stride).rounded(.down)) + lazyBufferRows
    first = Swift.max(0, first)
    last = Swift.min(count - 1, last)

    var rows: [RenderNode] = []
    if count > 0 && first <= last {
        for i in first ... last {
            let (key, view) = forEach.forEachChild(at: i)
            var nodes = evaluateResolved(view, context.appendingKey(key))
            if !nodes.isEmpty {
                nodes[0].layout.lazyIndex = i
                rows.append(nodes[0])
            }
        }
    }

    return RenderNode(id: context.id,
                      component: ContainerComponent(WidgetKey("lazyStack"),
                          role: .lazyStack(LazyInfo(axis: axis, rowExtent: rowExtent, spacing: spacing, totalCount: count),
                                           alignment: alignment)),
                      children: rows,
                      layout: LayoutInfo(alignment: alignment,
                                         lazy: LazyInfo(axis: axis, rowExtent: rowExtent,
                                                        spacing: spacing, totalCount: count)),
                      onRowExtent: { measured in
                          if measured > 0 && measured != rowExtent {
                              graph.setValue(measured, for: extentSource)
                              GraphContext.scheduleFlush()
                          }
                      },
                      onContentOrigin: { newOrigin in
                          if abs(newOrigin - origin) > 0.5 {
                              graph.setValue(newOrigin, for: originSource)
                              GraphContext.scheduleFlush()
                          }
                      })
}
