// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// A single item in a window's top toolbar. Basic support covers text labels and buttons; the
/// toolkit renders these with the platform-idiomatic toolbar (NSToolbar / GtkHeaderBar / QToolBar).
public struct ToolbarItemSpec {
    public enum Kind {
        case text(String)
        case button(title: String, action: @MainActor () -> Void)
    }
    public let kind: Kind
}

/// Wraps a view together with toolbar content. During evaluation it extracts the toolbar's buttons
/// and text into ``ToolbarItemSpec``s (reusing the normal Button/Text → RenderNode path) and attaches
/// them as a preference on the content node (collected up the tree by ``collectWindowPreferences``),
/// then renders the wrapped content unchanged.
public struct ToolbarHost<Content: View, Bar: View>: View, PrimitiveView {
    let content: Content
    let bar: Bar

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var items: [ToolbarItemSpec] = []
        for node in evaluateResolved(bar, context.appending(1)) {
            switch node.component.widgetKey.rawValue {
            case "button":
                items.append(ToolbarItemSpec(kind: .button(title: node.effectivePatch.title ?? "", action: node.effectiveAction ?? {})))
            case "label":
                items.append(ToolbarItemSpec(kind: .text(node.effectivePatch.text ?? "")))
            default:
                break
            }
        }

        var node = evaluate(content, context.appending(0)).first ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        var prefs = node.preferences ?? NodePreferences()
        prefs.toolbar = (prefs.toolbar ?? []) + items
        node.preferences = prefs
        return node
    }
}

extension View {
    /// Attach a top toolbar. Mirrors SwiftUI's `.toolbar { ... }`; the closure contains `Button`s
    /// and `Text`s placed in the window's native toolbar.
    public func toolbar<Bar: View>(@ViewBuilder _ content: () -> Bar) -> some View {
        ToolbarHost(content: self, bar: content())
    }
}
