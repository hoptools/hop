// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Value-based navigation, mirroring SwiftUI's `NavigationStack` / `NavigationLink(value:)` /
// `.navigationDestination(for:)` / `.navigationTitle(_:)`. The implementation is genuinely
// path-driven: a stack owns a path of pushed values, a link appends to it, a destination builds a
// view from the top value, and back pops it — no hard-coded view switching.

/// A view that presents a stack of views over a root, mirroring SwiftUI's `NavigationStack`. The
/// visible view is the destination for the top of the path (or the root when the path is empty),
/// shown beneath a bar with the navigation title and — when not at the root — a back button.
public struct NavigationStack<Content: View>: View, PrimitiveView {
    let content: Content
    let pathGet: @MainActor () -> [AnyHashable]
    let pathSet: @MainActor ([AnyHashable]) -> Void

    /// A stack with no externally-managed path (its path is always empty: shows the root, no pushes).
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.pathGet = { [] }
        self.pathSet = { _ in }
    }

    /// A stack whose navigation path is bound to `path`. Pushing a value appends to it; back removes
    /// the last element. Mirrors SwiftUI's `NavigationStack(path:root:)`.
    public init<Data: Hashable>(path: Binding<[Data]>, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.pathGet = { path.wrappedValue.map { AnyHashable($0) } }
        self.pathSet = { erased in path.wrappedValue = erased.map { $0.base as! Data } }
    }

    public typealias Body = Never
    public var body: Never { fatalError("NavigationStack has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let pathGet = self.pathGet, pathSet = self.pathSet
        let path = pathGet()

        // Install the push action in the environment for this stack's subtree (derived as a graph
        // attribute, so it flows down correctly under memoization), then evaluate the content. Titles
        // and destinations attached by the content are collected by walking the assembled subtree —
        // which is sound even when child composites are memoized (their cached nodes carry the data).
        let savedEnvironment = EnvironmentStore.currentAttr
        if let vg = GraphContext.viewGraph {
            EnvironmentStore.currentAttr = vg.derivedEnvironment(for: context.id + "·navenv") { env in
                env.navigationPush = { value in pathSet(pathGet() + [value]) }
            }
        }
        defer { EnvironmentStore.currentAttr = savedEnvironment }

        let rootNodes = evaluateResolved(content, context.appending(0))
        let rootPrefs = collectNavigationPreferences(rootNodes)
        let destinations = rootPrefs.destinations
        var title = rootPrefs.title

        var bodyNodes = rootNodes
        var showBack = false
        // If the path has a top value with a registered destination, that destination is what shows.
        if let top = path.last, let build = destinations[ObjectIdentifier(type(of: top.base))] {
            let pushedNodes = evaluateResolved(build(top), context.appending(1000 + path.count))
            if let pushedTitle = collectNavigationPreferences(pushedNodes).title { title = pushedTitle }
            bodyNodes = pushedNodes
            showBack = true
        }

        var barChildren: [RenderNode] = []
        if showBack {
            barChildren.append(RenderNode(id: context.id + "·back", kind: .button,
                patch: WidgetPatch(title: "‹ Back"),
                action: { var p = pathGet(); if !p.isEmpty { p.removeLast() }; pathSet(p) }))
        }
        barChildren.append(RenderNode(id: context.id + "·title", kind: .label,
                                      patch: WidgetPatch(text: title ?? "")))
        let bar = RenderNode(id: context.id + "·navbar", kind: .hstack, patch: WidgetPatch(spacing: 8),
                             children: barChildren)
        var body = bodyNodes.first ?? RenderNode(id: context.id + "·body", kind: .vstack)
        // The content area fills the space below the bar and centers its content — matching SwiftUI, where
        // navigation content is centered in the pane (a greedy fill via maxWidth/maxHeight: .infinity).
        body.layout.modifiers.append(.frame(FrameSpec(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)))
        return RenderNode(id: context.id, kind: .vstack, patch: WidgetPatch(spacing: 12),
                          children: [bar, body])
    }
}

/// A control that pushes a value onto the enclosing `NavigationStack`'s path when tapped. Mirrors
/// SwiftUI's `NavigationLink(_:value:)`.
public struct NavigationLink: View, PrimitiveView {
    let title: String
    let value: AnyHashable

    public init<P: Hashable>(_ title: String, value: P) {
        self.title = title
        self.value = AnyHashable(value)
    }

    public typealias Body = Never
    public var body: Never { fatalError("NavigationLink has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        // Capture the stack's push action (installed in the environment by NavigationStack) into the
        // button's action, so tapping later pushes onto the path. Reading through the graph records the
        // dependency, so this link re-resolves if the enclosing stack's push action changes.
        let push = currentEnvironment().navigationPush
        let value = self.value
        return RenderNode(id: context.id, kind: .button, patch: WidgetPatch(title: title),
                          action: { push?(value) })
    }
}

/// Registers a destination view builder for a value type with the enclosing `NavigationStack`.
struct _NavigationDestinationModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let typeKey: ObjectIdentifier
    let build: (AnyHashable) -> any View

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = passthrough(evaluate(content, context.appending(0)), context)
        var prefs = node.preferences ?? NodePreferences()
        var dests = prefs.navigationDestinations ?? [:]
        dests[typeKey] = build
        prefs.navigationDestinations = dests
        node.preferences = prefs
        return node
    }
}

/// Sets the navigation title for the enclosing `NavigationStack`.
struct _NavigationTitleModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let title: String

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = passthrough(evaluate(content, context.appending(0)), context)
        // Attach the title; an outer modifier overwrites an inner one on the shared passthrough node
        // (and `collectNavigationPreferences` takes the outermost), so an outer title wins (matches SwiftUI).
        var prefs = node.preferences ?? NodePreferences()
        prefs.navigationTitle = title
        node.preferences = prefs
        return node
    }
}

/// A transparent modifier returns its content unchanged (single node passthrough; multiple nodes
/// wrapped so exactly one node is produced).
@MainActor
private func passthrough(_ nodes: [RenderNode], _ context: RenderContext) -> RenderNode {
    nodes.count == 1 ? nodes[0] : RenderNode(id: context.id, kind: .vstack, children: nodes)
}

extension View {
    /// Associates a destination view with a presented value type. Mirrors SwiftUI's
    /// `.navigationDestination(for:destination:)`.
    public func navigationDestination<D: Hashable, V: View>(
        for data: D.Type, @ViewBuilder destination: @escaping (D) -> V
    ) -> some View {
        _NavigationDestinationModifier(content: self, typeKey: ObjectIdentifier(D.self),
                                       build: { destination($0.base as! D) })
    }

    /// Sets the title of the enclosing navigation stack. Mirrors SwiftUI's `.navigationTitle(_:)`.
    public func navigationTitle(_ title: String) -> some View {
        _NavigationTitleModifier(content: self, title: title)
    }
}
