// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Light/dark appearance, mirroring SwiftUI's `ColorScheme`, `.preferredColorScheme(_:)`, and the
// `\.colorScheme` environment value. `.preferredColorScheme` drives the whole window's native
// appearance (each toolkit has its own light/dark switch); `@Environment(\.colorScheme)` exposes the
// value to view code.

/// The light or dark appearance, mirroring SwiftUI's `ColorScheme`. `nonisolated` so its `Equatable`
/// conformance is usable from non-main-actor code (e.g. an app's plain model types).
public nonisolated enum ColorScheme: Equatable, Hashable {
    case light, dark
}

/// Collects the preferred color scheme contributed by the view tree (set by `.preferredColorScheme`,
/// read by the runtime, which applies it to the window). Like the toolbar/navigation collectors.
@MainActor
enum PreferredColorSchemeStore {
    static var current: ColorScheme?
}

/// Sets the window's preferred color scheme. Mirrors SwiftUI's `.preferredColorScheme(_:)`.
struct _PreferredColorSchemeModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let scheme: ColorScheme?

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let nodes = evaluate(content, context.appending(0))
        // Set after evaluating content so an outer preference wins over an inner one.
        PreferredColorSchemeStore.current = scheme
        return nodes.count == 1 ? nodes[0] : RenderNode(id: context.id, kind: .vstack, children: nodes)
    }
}

extension View {
    /// Sets the preferred color scheme (light/dark) for the enclosing window. Mirrors SwiftUI's
    /// `.preferredColorScheme(_:)`.
    public func preferredColorScheme(_ colorScheme: ColorScheme?) -> some View {
        _PreferredColorSchemeModifier(content: self, scheme: colorScheme)
    }
}
