// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// A hierarchical tree of rows derived from a recursive data model, mirroring SwiftUI's
/// `OutlineGroup(_:id:children:content:)`. Each element contributes a row (its title is extracted from
/// the `content` view, like ``List``'s row text) and, via the `children` key path, an optional child
/// collection that becomes the expandable subtree.
///
/// Placed inside a selection-bound `List { OutlineGroup(...) }`, the surrounding ``List`` injects the
/// selection binding into the produced `.outline` node (see `List.init(selection:content:)`); in a
/// `NavigationSplitView`'s leading column it becomes a source-list sidebar tree (`.sidebarOutline`).
/// Backed by the toolkit's native tree widget (NSOutlineView / GtkTreeListModel / QTreeWidget).
public struct OutlineGroup<Data, ID, Content>: View, PrimitiveView
    where Data: RandomAccessCollection, ID: Hashable, Content: View {
    private let buildRoots: @MainActor () -> [OutlineSpec.Node]

    public init(_ data: Data, id: KeyPath<Data.Element, ID>,
                children: KeyPath<Data.Element, Data?>,
                @ViewBuilder content: @escaping (Data.Element) -> Content) {
        buildRoots = { OutlineGroup.buildNodes(data, id: id, children: children, content: content) }
    }

    /// Recursively flatten the data model into `OutlineSpec.Node`s, extracting each row's title from
    /// the first node of its `content` view (mirroring `List`'s `rowText`).
    @MainActor
    private static func buildNodes(_ data: Data, id: KeyPath<Data.Element, ID>,
                                   children: KeyPath<Data.Element, Data?>,
                                   content: (Data.Element) -> Content) -> [OutlineSpec.Node] {
        data.map { element in
            let title = evaluateResolved(content(element), RenderContext(path: [])).first?.effectivePatch.text ?? ""
            let kids = element[keyPath: children].map {
                buildNodes($0, id: id, children: children, content: content)
            } ?? []
            return OutlineSpec.Node(id: AnyHashable(element[keyPath: id]),
                                    title: title, children: kids, selectable: true)
        }
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        // In a NavigationSplitView's leading column, render as a source-list sidebar tree; the widgetKey —
        // not a runtime flag — selects the styling so the toolkit bakes it in at creation.
        let sidebar = SidebarColumnContext.active
        return RenderNode(id: context.id, kind: sidebar ? .sidebarOutline : .outline,
                          component: OutlineComponent(spec: OutlineSpec(roots: buildRoots()), sidebar: sidebar))
    }
}

extension OutlineGroup where Data.Element: Identifiable, ID == Data.Element.ID {
    /// `OutlineGroup(_:children:content:)` for `Identifiable` elements (id derived from `\.id`).
    public init(_ data: Data, children: KeyPath<Data.Element, Data?>,
                @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.init(data, id: \.id, children: children, content: content)
    }
}

/// A collapsible group with a disclosure-triangle header that shows/hides its content, mirroring
/// SwiftUI's `DisclosureGroup`. Two forms are supported: a self-managed one (`DisclosureGroup("Title")
/// { … }`, expansion held in a per-identity graph source) and a bound one (`DisclosureGroup("Title",
/// isExpanded: $flag) { … }`). Composed from existing primitives — a header `.button` row over the
/// conditionally-included content in a leading-aligned `.vstack` — so it works uniformly on every
/// toolkit without a native composite-disclosure widget.
public struct DisclosureGroup<Content: View>: View, PrimitiveView {
    private let title: String
    private let isExpanded: Binding<Bool>?
    private let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isExpanded = nil
        self.content = content()
    }

    public init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isExpanded = isExpanded
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let graph = GraphContext.requireCurrent()
        let binding = isExpanded
        // Self-managed form: a per-identity source survives re-evaluation (like @State's out-of-struct
        // box); reading it makes this render depend on the expansion state.
        let source = binding == nil ? IdentitySourceStore.boolSource(context.id, graph) : nil
        let expanded: Bool = binding?.wrappedValue ?? source.map { graph.read($0) } ?? false
        let toggle: @MainActor () -> Void = {
            if let binding {
                binding.wrappedValue.toggle()
            } else if let source {
                graph.setValue(!graph.read(source), for: source)
                GraphContext.scheduleFlush()
            }
        }

        let header = RenderNode(id: context.id + "·hdr", kind: .button,
                                patch: WidgetPatch(title: (expanded ? "▾  " : "▸  ") + title),
                                action: toggle)
        var children = [header]
        if expanded {
            children += evaluate(content, context.appending(1))
        }
        return RenderNode(id: context.id, kind: .vstack,
                          patch: WidgetPatch(spacing: 6),
                          children: children,
                          layout: LayoutInfo(alignment: Alignment(horizontal: .leading, vertical: .center)))
    }
}
