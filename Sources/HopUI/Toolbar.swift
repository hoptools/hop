// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// A single item in a window's top toolbar. Basic support covers text labels and buttons; the
/// backend renders these with the platform-idiomatic toolbar (NSToolbar / GtkHeaderBar / QToolBar).
public struct ToolbarItemSpec {
    public enum Kind {
        case text(String)
        case button(title: String, action: @MainActor () -> Void)
    }
    public let kind: Kind
}

/// Collects toolbar items produced during a render pass so the runtime can install them on the
/// window. The whole UI runs on the main actor and renders synchronously, so a simple shared list
/// suffices (mirrors how SwiftUI's toolbar preferences bubble up to the hosting scene).
@MainActor
enum ToolbarCollector {
    static var items: [ToolbarItemSpec] = []
    static func reset() { items = [] }
    static func add(_ newItems: [ToolbarItemSpec]) { items += newItems }
}

/// Wraps a view together with toolbar content. During evaluation it extracts the toolbar's buttons
/// and text into ``ToolbarItemSpec``s (reusing the normal Button/Text → RenderNode path) and hands
/// them to ``ToolbarCollector``, then renders the wrapped content unchanged.
public struct ToolbarHost<Content: View, Bar: View>: View, PrimitiveView {
    let content: Content
    let bar: Bar

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var items: [ToolbarItemSpec] = []
        for node in evaluate(bar, context.appending(1)) {
            switch node.kind {
            case .button:
                items.append(ToolbarItemSpec(kind: .button(title: node.patch.title ?? "", action: node.action ?? {})))
            case .label:
                items.append(ToolbarItemSpec(kind: .text(node.patch.text ?? "")))
            default:
                break
            }
        }
        ToolbarCollector.add(items)

        let contentNodes = evaluate(content, context.appending(0))
        return contentNodes.first ?? RenderNode(id: context.id, kind: .vstack)
    }
}

extension View {
    /// Attach a top toolbar. Mirrors SwiftUI's `.toolbar { ... }`; the closure contains `Button`s
    /// and `Text`s placed in the window's native toolbar.
    public func toolbar<Bar: View>(@ViewBuilder _ content: () -> Bar) -> some View {
        ToolbarHost(content: self, bar: content())
    }
}
