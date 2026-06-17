// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Layout modifiers (`.padding`, `.frame`) that participate in HopUI's own layout engine. Each wraps a
// view and appends a `LayoutModifier` to the wrapped node, composed innermost-first — so `.padding().
// frame()` behaves like SwiftUI (frame around padded content).

/// Wraps a view, appending a layout modifier to its node. Not a widget itself.
struct _LayoutModifierView<Content: View>: View, PrimitiveView {
    let content: Content
    let modifier: LayoutModifier

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.layout.modifiers.append(modifier)
        return node
    }
}

extension View {
    /// Pads all edges by `length`. Mirrors SwiftUI's `.padding(_:)`.
    public func padding(_ length: Double = 16) -> some View {
        _LayoutModifierView(content: self, modifier: .padding(EdgeInsets(top: length, leading: length, bottom: length, trailing: length)))
    }

    /// Pads the given edges by `length` (default 16). Mirrors SwiftUI's `.padding(_:_:)`.
    public func padding(_ edges: Edge.Set, _ length: Double? = nil) -> some View {
        let l = length ?? 16
        var insets = EdgeInsets()
        if edges.contains(.top) { insets.top = l }
        if edges.contains(.leading) { insets.leading = l }
        if edges.contains(.bottom) { insets.bottom = l }
        if edges.contains(.trailing) { insets.trailing = l }
        return _LayoutModifierView(content: self, modifier: .padding(insets))
    }

    /// Pads by explicit insets. Mirrors SwiftUI's `.padding(_:)` with `EdgeInsets`.
    public func padding(_ insets: EdgeInsets) -> some View {
        _LayoutModifierView(content: self, modifier: .padding(insets))
    }

    /// Constrains the view to a fixed size (either axis optional), aligning the content within. Mirrors
    /// SwiftUI's `.frame(width:height:alignment:)`.
    public func frame(width: Double? = nil, height: Double? = nil, alignment: Alignment = .center) -> some View {
        _LayoutModifierView(content: self, modifier: .frame(FrameSpec(width: width, height: height, alignment: alignment)))
    }

    /// Constrains the view with min/ideal/max bounds (e.g. `maxWidth: .infinity` to fill). Mirrors
    /// SwiftUI's flexible `.frame(...)`.
    public func frame(minWidth: Double? = nil, idealWidth: Double? = nil, maxWidth: Double? = nil,
                      minHeight: Double? = nil, idealHeight: Double? = nil, maxHeight: Double? = nil,
                      alignment: Alignment = .center) -> some View {
        _LayoutModifierView(content: self, modifier: .frame(FrameSpec(
            width: idealWidth, height: idealHeight,
            minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight,
            alignment: alignment)))
    }
}
