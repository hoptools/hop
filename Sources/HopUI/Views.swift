// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// A line of text. Mirrors SwiftUI's `Text`.
public struct Text: View, PrimitiveView {
    let content: String
    public init(_ content: String) { self.content = content }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        // Read inherited text styling from the ambient environment (set by .font/.fontWeight/
        // .foregroundStyle on an ancestor), baking it into the node so the toolkit can apply it.
        let environment = EnvironmentStore.current
        return RenderNode(id: context.id, kind: .label,
                          patch: WidgetPatch(text: content,
                                             foregroundColor: environment.foregroundColor,
                                             font: environment.font,
                                             fontWeight: environment.fontWeightOverride))
    }
}

/// A tappable button with a title and an action. Mirrors a common SwiftUI `Button` form.
public struct Button: View, PrimitiveView {
    let title: String
    let action: @MainActor () -> Void
    public init(_ title: String, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.action = action
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        RenderNode(id: context.id, kind: .button, patch: WidgetPatch(title: title), action: action)
    }
}

/// An editable single-line text field bound to a `String`. Mirrors a common SwiftUI `TextField`
/// form. Reading `text.wrappedValue` registers a dependency on the bound state, so the field
/// re-renders when that state changes elsewhere; edits flow back through the binding.
public struct TextField: View, PrimitiveView {
    let placeholder: String
    let text: Binding<String>
    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self.text = text
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let binding = text
        return RenderNode(id: context.id, kind: .textField,
                          patch: WidgetPatch(value: text.wrappedValue, placeholder: placeholder),
                          onChange: { binding.wrappedValue = $0 })
    }
}

/// A two-column navigation container with a sidebar and a detail area, mirroring SwiftUI's
/// `NavigationSplitView`. The sidebar typically holds a selection-bound `List`; the detail shows
/// content for the current selection. Backed by a native split widget (NSSplitView / GtkPaned /
/// QSplitter) so the divider is draggable and panes resize.
///
/// This is the foundation for richer navigation: the detail builder can later host a
/// `NavigationStack` / `navigationDestination(for:)` that switches on the sidebar selection.
public struct NavigationSplitView<Sidebar: View, Detail: View>: View, PrimitiveView {
    let sidebar: Sidebar
    let detail: Detail

    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        // A List in the leading column renders as a source-list sidebar (matching SwiftUI's automatic
        // `.sidebar` list style there); bracket the flag around the sidebar evaluation only.
        let savedSidebar = SidebarColumnContext.active
        SidebarColumnContext.active = true
        let sidebarChild = singleChild(evaluate(sidebar, context.appending(0)), id: context.id + "·sidebar")
        SidebarColumnContext.active = savedSidebar
        let detailChild = singleChild(evaluate(detail, context.appending(1)), id: context.id + "·detail")
        return RenderNode(id: context.id, kind: .splitView, children: [sidebarChild, detailChild])
    }

    /// A split pane must be exactly one widget; collapse multiple nodes into a vstack wrapper.
    private func singleChild(_ nodes: [RenderNode], id: String) -> RenderNode {
        nodes.count == 1 ? nodes[0] : RenderNode(id: id, kind: .vstack, children: nodes)
    }
}

/// A lazily-virtualized list with single selection. The initializer mirrors SwiftUI's
/// `List(_:id:selection:rowContent:)` exactly, so the same call site compiles against HopUI and
/// SwiftUI. Rows are realized only when visible; for the native list widgets each visible row's
/// text is extracted from its `rowContent` view on demand, so a 100,000-row list stays cheap.
public struct List<SelectionValue, RowContent>: View, PrimitiveView
    where SelectionValue: Hashable, RowContent: View {
    private enum Source {
        /// Flat data-driven list (maps to `.list`/`.sidebarList`).
        case flat(count: Int, rowText: @MainActor (Int) -> String,
                  selectedIndex: @MainActor () -> Int?, select: @MainActor (Int?) -> Void)
        /// Hierarchical content (an `OutlineGroup`) with selection (maps to `.outline`/`.sidebarOutline`).
        case hierarchical(content: @MainActor () -> RowContent,
                          selectedID: @MainActor () -> SelectionValue?,
                          select: @MainActor (SelectionValue?) -> Void)
    }
    private let source: Source

    public init<Data: RandomAccessCollection>(
        _ data: Data,
        id: KeyPath<Data.Element, SelectionValue>,
        selection: Binding<SelectionValue?>,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) {
        let count = data.count
        let rowText: @MainActor (Int) -> String = { index in
            let elementIndex = data.index(data.startIndex, offsetBy: index)
            return evaluate(rowContent(data[elementIndex]), RenderContext(path: [])).first?.patch.text ?? ""
        }
        let resolve: @MainActor () -> Int? = {
            guard let selected = selection.wrappedValue else { return nil }
            var index = 0
            for element in data { if element[keyPath: id] == selected { return index }; index += 1 }
            return nil
        }
        let select: @MainActor (Int?) -> Void = { index in
            if let index {
                let elementIndex = data.index(data.startIndex, offsetBy: index)
                selection.wrappedValue = data[elementIndex][keyPath: id]
            } else {
                selection.wrappedValue = nil
            }
        }
        source = .flat(count: count, rowText: rowText, selectedIndex: resolve, select: select)
    }

    /// A selection-bound list whose content is hierarchical (an `OutlineGroup`), mirroring SwiftUI's
    /// `List(selection:) { OutlineGroup(...) }` — rendered as a native outline tree.
    public init(selection: Binding<SelectionValue?>, @ViewBuilder content: @escaping @MainActor () -> RowContent) {
        source = .hierarchical(content: content,
                               selectedID: { selection.wrappedValue },
                               select: { selection.wrappedValue = $0 })
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        switch source {
        case let .flat(count, rowText, selectedIndex, select):
            // In a NavigationSplitView's leading column, render as a source-list sidebar (the kind — not a
            // runtime flag — selects the styling so the toolkit bakes it in at creation).
            let kind: WidgetKind = SidebarColumnContext.active ? .sidebarList : .list
            return RenderNode(id: context.id, kind: kind, list: ListSpec(
                count: count, rowText: rowText, selectedIndex: selectedIndex(), onSelect: select))
        case let .hierarchical(content, selectedID, select):
            // The content is an OutlineGroup producing an `.outline`/`.sidebarOutline` node; inject selection.
            var node = evaluate(content(), context.appending(0)).first
                ?? RenderNode(id: context.id + "·outline", kind: .outline, outline: OutlineSpec(roots: []))
            node.outline?.selectedID = selectedID().map { AnyHashable($0) }
            node.outline?.onSelect = { anyID in select(anyID?.base as? SelectionValue) }
            return node
        }
    }
}

/// Ambient flag set while a ``NavigationSplitView`` evaluates its leading column, so a ``List`` there
/// knows to render as a source-list sidebar. Mirrors SwiftUI applying `.sidebar` list style automatically.
@MainActor
enum SidebarColumnContext {
    static var active = false
    static func reset() { active = false }
}

/// A horizontal slider bound to a `Double` within a closed range. Mirrors SwiftUI's `Slider`.
/// Reading `value.wrappedValue` registers a dependency on the bound state, so the slider tracks
/// changes made elsewhere (e.g. the counter buttons); dragging flows back through the binding.
public struct Slider: View, PrimitiveView {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    public init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1) {
        self.value = value
        self.range = range
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let binding = value
        return RenderNode(id: context.id, kind: .slider,
                          patch: WidgetPatch(doubleValue: value.wrappedValue,
                                             minValue: range.lowerBound, maxValue: range.upperBound),
                          onChangeDouble: { binding.wrappedValue = $0 })
    }
}

/// A vertical stack of child views. Mirrors SwiftUI's `VStack`. Laid out by HopUI's own layout engine.
public struct VStack<Content: View>: View, PrimitiveView {
    let alignment: HorizontalAlignment
    let spacing: Double?
    let content: Content
    public init(alignment: HorizontalAlignment = .center, spacing: Double? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        RenderNode(id: context.id, kind: .vstack, patch: WidgetPatch(spacing: spacing),
                   children: evaluate(content, context.appending(0)),
                   layout: LayoutInfo(alignment: Alignment(horizontal: alignment, vertical: .center)))
    }
}

/// A horizontal stack of child views. Mirrors SwiftUI's `HStack`. Laid out by HopUI's own layout engine.
public struct HStack<Content: View>: View, PrimitiveView {
    let alignment: VerticalAlignment
    let spacing: Double?
    let content: Content
    public init(alignment: VerticalAlignment = .center, spacing: Double? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        RenderNode(id: context.id, kind: .hstack, patch: WidgetPatch(spacing: spacing),
                   children: evaluate(content, context.appending(0)),
                   layout: LayoutInfo(alignment: Alignment(horizontal: .center, vertical: alignment)))
    }
}

/// Children overlaid back-to-front, each aligned within the stack's bounds. Mirrors SwiftUI's `ZStack`.
public struct ZStack<Content: View>: View, PrimitiveView {
    let alignment: Alignment
    let content: Content
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        RenderNode(id: context.id, kind: .zstack, children: evaluate(content, context.appending(0)),
                   layout: LayoutInfo(alignment: alignment))
    }
}

/// A flexible space that expands along its containing stack's axis. Mirrors SwiftUI's `Spacer`.
public struct Spacer: View, PrimitiveView {
    let minLength: Double?
    public init(minLength: Double? = nil) { self.minLength = minLength }

    public typealias Body = Never
    public var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        RenderNode(id: context.id, kind: .spacer,
                   layout: LayoutInfo(spacerMinLength: minLength ?? 0))
    }
}
