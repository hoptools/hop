// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

// SwiftUI's non-lazy, column-*aligned* grid: `Grid` + `GridRow`. Every column is sized to the widest cell
// in that column across all rows (a "table"), so cells line up vertically even when their contents differ
// in width. The layout is entirely framework-side — the `LayoutEngine` runs a 2-pass measure → place over
// the grid's `GridRow` children (`role(of:) == .grid` / `.gridRow`) and positions each cell with the
// existing `setFrame`; no per-backend code is involved (cells are ordinary widgets). Every call site here
// compiles unchanged against HopUI and Apple's SwiftUI.
//
// The lazy, virtualizing siblings (`LazyVGrid`/`LazyHGrid`) are a separate, later phase; `Grid` is for
// bounded, column-aligned content and intentionally measures all its cells (that is its defining semantic).

// MARK: - Grid

/// A non-lazy, column-aligned grid. Columns are sized to the widest cell across all rows; rows to the
/// tallest cell. A view placed directly in the grid (not inside a `GridRow`) spans the full width.
/// Mirrors SwiftUI's `Grid`.
public struct Grid<Content: View>: View, PrimitiveView {
    let alignment: Alignment
    let horizontalSpacing: CGFloat?
    let verticalSpacing: CGFloat?
    let content: Content

    public init(alignment: Alignment = .center,
                horizontalSpacing: CGFloat? = nil,
                verticalSpacing: CGFloat? = nil,
                @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let config = GridConfig(alignment: alignment,
                                horizontalSpacing: horizontalSpacing.map { Double($0) },
                                verticalSpacing: verticalSpacing.map { Double($0) })
        return RenderNode(id: context.id,
                          component: ContainerComponent.grid(config),
                          children: evaluate(content, context.appending(0)),
                          layout: LayoutInfo(alignment: alignment))
    }
}

// MARK: - GridRow

/// One row of a `Grid`: each child view is a cell, positioned by the enclosing grid into the column it
/// occupies (a cell's column = the running sum of prior cells' spans). The optional `alignment` is the
/// vertical guide used to place this row's cells within their (taller) row. Mirrors SwiftUI's `GridRow`.
public struct GridRow<Content: View>: View, PrimitiveView {
    let alignment: VerticalAlignment?
    let content: Content

    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        RenderNode(id: context.id,
                   component: ContainerComponent.gridRow(alignment),
                   children: evaluate(content, context.appending(0)),
                   layout: LayoutInfo(alignment: Alignment(horizontal: .center, vertical: alignment ?? .center)))
    }
}

// MARK: - Cell / column modifiers

extension View {
    /// Tells a grid cell to span `count` columns. The cell's width becomes the sum of those columns (plus
    /// the spacing between them); spanning does NOT widen the columns. Mirrors SwiftUI's `.gridCellColumns`.
    public func gridCellColumns(_ count: Int) -> some View {
        _GridCellColumnsModifier(content: self, count: Swift.max(1, count))
    }

    /// Sets the horizontal alignment guide for the WHOLE column this cell occupies. Mirrors SwiftUI's
    /// `.gridColumnAlignment`.
    public func gridColumnAlignment(_ guide: HorizontalAlignment) -> some View {
        _GridColumnAlignmentModifier(content: self, guide: guide)
    }

    /// Positions this cell's content within its cell rect using a `UnitPoint` anchor (overriding the
    /// column/row alignment guides). Mirrors SwiftUI's `.gridCellAnchor`.
    public func gridCellAnchor(_ anchor: UnitPoint) -> some View {
        _GridCellAnchorModifier(content: self, anchor: anchor)
    }

    /// Tells a grid cell NOT to stretch to fill its cell on the given axes — it keeps its intrinsic extent
    /// there and is positioned by alignment instead. Mirrors SwiftUI's `.gridCellUnsizedAxes`.
    public func gridCellUnsizedAxes(_ axes: Axis.Set) -> some View {
        _GridCellUnsizedAxesModifier(content: self, axes: axes)
    }
}

/// Stamps `gridCellColumns` onto the wrapped cell node, for the enclosing grid's layout to read (the same
/// metadata-stamping pattern as `.tag`/`.tabItem`: evaluate the content, mutate its first node, return it).
struct _GridCellColumnsModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let count: Int
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.gridCellColumns = count
        return node
    }
}

/// Stamps `gridColumnAlignment` onto the wrapped cell node.
struct _GridColumnAlignmentModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let guide: HorizontalAlignment
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.gridColumnAlignment = guide
        return node
    }
}

/// Stamps `gridCellAnchor` onto the wrapped cell node.
struct _GridCellAnchorModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let anchor: UnitPoint
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.gridCellAnchor = anchor
        return node
    }
}

/// Stamps `gridCellUnsizedAxes` onto the wrapped cell node.
struct _GridCellUnsizedAxesModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let axes: Axis.Set
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.gridCellUnsizedAxes = axes
        return node
    }
}
