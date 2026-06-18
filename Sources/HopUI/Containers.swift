// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

// Grouping containers (GroupBox / Section / Form) and a tabbed container (TabView). GroupBox/Section/Form
// are composed around a native "card" container (`.groupBox`), which each toolkit draws with a rounded,
// bordered, filled chrome. TabView composes a tab-button bar over switched content. Every call site
// compiles against HopUI and Apple's SwiftUI.

// MARK: - GroupBox

/// A titled, bordered grouping box. Mirrors SwiftUI's `GroupBox`.
public struct GroupBox<Content: View>: View {
    let title: String?
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.title = nil
        self.content = content()
    }

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        _CardBox {
            VStack(alignment: .leading, spacing: 8) {
                if let title { Text(title).fontWeight(.semibold) }
                content
            }
            .padding(14)
        }
    }
}

/// The native "card" container behind ``GroupBox`` / ``Section`` content. Produces a `.groupBox` node
/// (one padded child); the toolkit draws the rounded bordered chrome.
struct _CardBox<Content: View>: View, PrimitiveView {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    typealias Body = Never
    var body: Never { fatalError("_CardBox has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        RenderNode(id: context.id,
                   component: ContainerComponent(.groupBox,
                       role: .stack(axis: .vertical, spacing: nil, alignment: Alignment(horizontal: .leading, vertical: .center))),
                   children: evaluate(content, context.appending(0)),
                   layout: LayoutInfo(alignment: Alignment(horizontal: .leading, vertical: .center)))
    }
}

// MARK: - Section

/// A labeled group of content, mirroring SwiftUI's `Section`. Standalone or inside a ``Form`` it renders
/// an optional header above a carded group of its content.
public struct Section<Content: View>: View {
    let header: String?
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.header = nil
        self.content = content()
    }

    public init(_ header: String, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header).fontWeight(.semibold).foregroundStyle(.gray)
            }
            _CardBox {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(14)
            }
        }
    }
}

/// Internal hook letting a selection-bound ``List`` recognize a ``Section`` structurally — pulling its
/// header and rows to build a native sectioned list (a 2-level outline: non-selecting group header over
/// selectable row leaves) — rather than rendering ``Section``'s standalone carded body.
protocol _ListSectionContent {
    var listSectionHeader: String? { get }
    var listSectionContent: any View { get }
}

extension Section: _ListSectionContent {
    var listSectionHeader: String? { header }
    var listSectionContent: any View { content }
}

// MARK: - Form

/// A scrolling container that groups data-entry controls into sections. Mirrors SwiftUI's `Form`.
public struct Form<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(16)
        }
    }
}

// MARK: - TabView

/// A tabbed container backed by the toolkit's native tab widget (NSTabView / GtkNotebook / QTabWidget).
/// Mirrors SwiftUI's `TabView`. Each page is labeled with `.tabItem { … }`; every page stays mounted (the
/// native widget shows the selected one).
///
/// Selection comes in two forms, both like SwiftUI:
/// - Plain `TabView { … }` (`SelectionValue == Never`): the active tab is held in a per-identity source.
/// - `TabView(selection:) { … }`: each page carries a `.tag(_:)` identifier matched against the binding,
///   so the active tab is driven by (and reported back to) external state.
public struct TabView<SelectionValue: Hashable, Content: View>: View, PrimitiveView {
    let content: Content
    let selection: Binding<SelectionValue>?

    public typealias Body = Never
    public var body: Never { fatalError("TabView has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let graph = GraphContext.requireCurrent()
        let pages = evaluate(content, context.appending(0))
        let count = pages.count
        let titles = pages.enumerated().map { index, page in page.tabLabel ?? "Tab \(index + 1)" }

        let current: Int
        let onSelect: @MainActor (Int) -> Void
        if let selection {
            // Tab identifiers: each page's `.tag(_:)` value (falling back to its position) is matched against
            // the binding to find the active tab; a user switch maps the new index back to its tag value.
            let tags = pages.enumerated().map { index, page in page.tag ?? AnyHashable(index) }
            current = tags.firstIndex(of: AnyHashable(selection.wrappedValue)) ?? 0
            onSelect = { index in
                guard index >= 0, index < tags.count, let value = tags[index].base as? SelectionValue else { return }
                selection.wrappedValue = value
                GraphContext.scheduleFlush()
            }
        } else {
            // No binding: hold the selected index in a per-identity source so the tab survives re-renders.
            let selSource = IdentitySourceStore.intSource(context.id, graph)
            current = count == 0 ? 0 : Swift.min(Swift.max(graph.read(selSource), 0), count - 1)
            onSelect = { index in
                graph.setValue(index, for: selSource)
                GraphContext.scheduleFlush()
            }
        }

        // Each page is wrapped in a centering layer so the native page area lays its content out; all pages
        // stay mounted as children (the native widget shows `current`), so switching keeps page state.
        let wrapped = pages.enumerated().map { index, page in
            RenderNode(id: context.id + "·page\(index)", component: ContainerComponent.zstack(alignment: .center), children: [page],
                       layout: LayoutInfo(alignment: .center))
        }
        return RenderNode(id: context.id,
                          component: TabViewComponent(spec: TabSpec(titles: titles, selectedIndex: current, onSelect: onSelect)),
                          children: wrapped)
    }
}

extension TabView where SelectionValue == Never {
    /// A `TabView` whose active tab is managed internally (no external binding).
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = nil
    }
}

extension TabView {
    /// A `TabView` whose active tab is bound to `selection`, matched against each page's `.tag(_:)`.
    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
    }
}

extension View {
    /// Labels a ``TabView`` page with the tab to show in the tab bar. Mirrors SwiftUI's `.tabItem`.
    /// HopUI's tab bar uses the label's text (its icon, if any, is ignored).
    public func tabItem<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        _TabItemModifier(content: self, label: label())
    }
}

/// Stamps a tab title (extracted from `label`) onto the wrapped page node, for ``TabView`` to read.
struct _TabItemModifier<Content: View, Label: View>: View, PrimitiveView {
    let content: Content
    let label: Label

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.tabLabel = firstText(in: evaluateResolved(label, context.appending(1))) ?? node.tabLabel
        return node
    }
}

/// The first text found in a node subtree (a tab label may be a `Text` or a `Label` of icon + text).
@MainActor private func firstText(in nodes: [RenderNode]) -> String? {
    for node in nodes {
        if let text = node.effectivePatch.text { return text }
        if let text = firstText(in: node.children) { return text }
    }
    return nil
}
