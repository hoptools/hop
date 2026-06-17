// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Tap gestures, mirroring SwiftUI's `.onTapGesture(count:perform:)`. The handler is a cross-cutting
// attachment on the wrapped view's ``RenderNode`` (like `.fileImporter`/`.onScroll`); each backend
// installs a native tap/click recognizer on the widget that invokes it (NSClickGestureRecognizer /
// GtkGestureClick / a Qt event filter / WinUI's Tapped event).

/// A tap-gesture handler attached via `.onTapGesture`: how many taps are required and what to run. Public
/// so the per-backend toolkits (separate modules) can read it when wiring the native recognizer.
public struct TapGestureSpec {
    /// Number of taps required to fire (1 = single tap, 2 = double tap). Mirrors `.onTapGesture(count:)`.
    public let count: Int
    public let action: @MainActor () -> Void
    public init(count: Int, action: @escaping @MainActor () -> Void) {
        self.count = count
        self.action = action
    }
}

/// Attaches a tap handler to the wrapped view's node. Mirrors `_AccessibilityModifier`/`_FileImporterModifier`:
/// it lands the handler on the content's first rendered node (and is carried onto a composite via
/// ``RenderNode/applyWrapperState(from:)``).
struct _TapGestureModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let spec: TapGestureSpec

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.onTap = spec
        return node
    }
}

extension View {
    /// Runs `action` when the view is tapped `count` times. Mirrors SwiftUI's
    /// `.onTapGesture(count:perform:)`, so the same call site compiles against HopUI and Apple's SwiftUI.
    public func onTapGesture(count: Int = 1, perform action: @escaping @MainActor () -> Void) -> some View {
        _TapGestureModifier(content: self, spec: TapGestureSpec(count: count, action: action))
    }
}
