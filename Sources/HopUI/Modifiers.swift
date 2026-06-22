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

/// A per-view modifier that records a property on the wrapped view's node patch (mirrors
/// `_AccessibilityModifier`). The patch lands on the view's first rendered node — and via
/// ``RenderNode/applyWrapperState(from:)`` onto a composite's first node — so it behaves uniformly on
/// primitives and composites.
struct _PatchModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let apply: (inout WidgetPatch) -> Void
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        let nodes = evaluate(content, context.appending(0))
        var node = nodes.first ?? RenderNode(id: context.id, component: ContainerComponent.vstack(), children: nodes)
        apply(&node.patch)
        return node
    }
}

extension View {
    /// Sets the transparency of this view and its subtree: 0 = fully transparent, 1 = opaque. Mirrors
    /// SwiftUI's `.opacity(_:)`. The toolkit applies a native, compositing opacity, so it dims the whole
    /// subtree (not just the immediate widget).
    public func opacity(_ opacity: Double) -> some View {
        _PatchModifier(content: self) { $0.opacity = opacity }
    }

    /// Disables (or enables) this view and the controls within it. A disabled control is dimmed and does
    /// not respond to input. Mirrors SwiftUI's `.disabled(_:)`; like SwiftUI, once an ancestor disables a
    /// subtree a descendant cannot re-enable it (the values accumulate).
    public func disabled(_ disabled: Bool) -> some View {
        _PatchModifier(content: self) { $0.isEnabled = ($0.isEnabled ?? true) && !disabled }
    }

    /// Runs `action` when the user submits the text field this is applied to (presses Return). Mirrors
    /// SwiftUI's `.onSubmit(_:)`. The handler lands on the wrapped view's node, so apply it to a
    /// `TextField`/`SecureField` (e.g. `TextField(...).onSubmit { ... }`).
    public func onSubmit(perform action: @escaping @MainActor () -> Void) -> some View {
        _OnSubmitModifier(content: self, action: action)
    }
}

/// Lands an `.onSubmit` handler on the wrapped view's node (like `_AccessibilityModifier`, but the handler
/// is a `RenderNode` field rather than a patch field — closures aren't part of `WidgetPatch` equality).
struct _OnSubmitModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let action: @MainActor () -> Void
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.onSubmit = action
        return node
    }
}
