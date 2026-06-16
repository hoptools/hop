// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// The kinds of native widget a ``RenderNode`` can map to. The toolkit translates each to a
/// concrete toolkit widget (GtkBox/NSStackView, GtkLabel/NSTextField, GtkButton/NSButton, …).
public enum WidgetKind: Equatable {
    case window
    case vstack
    case hstack
    case label
    case button
    case textField
    case slider
    case list
    /// A `List` in the leading (sidebar) column of a ``NavigationSplitView``: rendered as a macOS-style
    /// source list / sidebar (inset rounded selection, sidebar material). Styling is baked in at widget
    /// creation so it never reloads a live table (which would clobber the bound selection).
    case sidebarList
    /// A two-pane navigation split (sidebar + detail), backed by a native split widget.
    case splitView
    /// A custom-drawn vector shape, rendered via the toolkit's native 2D drawing API
    /// (CoreGraphics / Cairo / QPainter). Carries a ``ShapeSpec`` instead of child widgets.
    case shape
    /// A button that presents a drop-down of actions (``Menu``). Carries a ``MenuContent``.
    case menu
    /// A drop-down for choosing one value from a set (``Picker``). Carries a ``PickerSpec``.
    case picker
    /// A date/time chooser (``DatePicker``), backed by the toolkit's native control (NSDatePicker /
    /// GtkCalendar+spin / QDateTimeEdit). Carries a ``DatePickerSpec``.
    case datePicker
    /// A separator line (``Divider``), or a separator entry within a menu.
    case separator
    /// A progress bar (``ProgressView``): determinate (a fraction) or indeterminate (animated).
    case progress
    /// An overlapping container (``ZStack``); a plain absolute-positioning layer.
    case zstack
    /// A flexible gap (``Spacer``); an empty (invisible) widget sized by the layout engine.
    case spacer
    /// A scrollable viewport (``ScrollView``) wrapping engine-laid-out content.
    case scroll
    /// A ``GeometryReader``: an absolute-positioning layer that reports its laid-out size back to its
    /// content closure (via a graph source), so content can depend on the available geometry.
    case geometry
    /// A virtualizing ``LazyVStack``/``LazyHStack``: an absolute-positioning layer holding only the
    /// currently-visible window of rows (sized to the full content extent so it scrolls correctly).
    case lazyStack
    /// A hierarchical disclosure tree (``OutlineGroup`` / `List(_:children:)`), backed by a native tree
    /// widget (NSOutlineView / GtkTreeListModel / QTreeWidget). Carries an ``OutlineSpec``.
    case outline
    /// An `.outline` in a `NavigationSplitView`'s leading column — rendered as a source-list sidebar tree.
    case sidebarOutline
    /// A raster/symbol image (``Image``), backed by a native image widget (NSImageView / GtkPicture /
    /// QLabel+QPixmap). Carries an ``ImageSpec``.
    case image
    /// A boolean on/off control (``Toggle``), backed by a native switch (NSSwitch / GtkSwitch / QCheckBox).
    /// Carries `patch.boolValue` and reports changes via `onChangeBool`.
    case toggle
    /// A masked text entry (``SecureField``): like `.textField` but the characters are hidden
    /// (NSSecureTextField / GtkEntry with visibility off / QLineEdit in password mode).
    case secureField
    /// A bordered, rounded "card" container (``GroupBox`` / ``Section`` / ``Form`` grouping), drawn by the
    /// toolkit (NSView layer / GTK `.card` / QFrame stylesheet). Laid out as a vertical stack of its
    /// content; the chrome is baked in at creation.
    case groupBox
    /// A tabbed container (``TabView``) backed by the toolkit's native tab widget (NSTabView /
    /// GtkNotebook / QTabWidget). Each child is a page; ``TabSpec`` carries the tab titles, selection,
    /// and the user-selection callback. A native composite (the widget lays out the selected page).
    case tabView
}

/// How an ``Image`` scales to fill a frame larger or smaller than its natural size. Mirrors
/// SwiftUI's `ContentMode`.
public enum ContentMode: Equatable, Sendable {
    /// Scale to fit entirely within the frame, preserving aspect ratio (may letterbox).
    case fit
    /// Scale to fill the frame, preserving aspect ratio (may crop / clip).
    case fill
}

/// Configures a `.tabView`: the tab titles (one per page child, in order), the selected page index, and
/// the callback fired when the user switches tabs. Reapplied on each reconcile (not `Equatable`); the
/// toolkit builds the native tab widget's tabs from the page children + these titles.
public struct TabSpec {
    public let titles: [String]
    public var selectedIndex: Int
    public var onSelect: @MainActor (Int) -> Void

    public init(titles: [String], selectedIndex: Int = 0,
                onSelect: @escaping @MainActor (Int) -> Void = { _ in }) {
        self.titles = titles
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
    }
}

/// Describes a lazily-virtualized list. The toolkit drives a native list widget that pulls
/// `rowText` only for visible rows, so a list of 100,000 rows materializes only what's on screen.
public struct ListSpec {
    public let count: Int
    public let rowText: @MainActor (Int) -> String
    public let selectedIndex: Int?
    public let onSelect: @MainActor (Int?) -> Void

    public init(count: Int, rowText: @escaping @MainActor (Int) -> String,
                selectedIndex: Int?, onSelect: @escaping @MainActor (Int?) -> Void) {
        self.count = count
        self.rowText = rowText
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
    }
}

/// Describes a hierarchical disclosure tree for a `.outline`/`.sidebarOutline` node. The toolkit builds a
/// native tree from `roots`, reflects `selectedID`, and reports user selection via `onSelect`. Not
/// `Equatable` — reapplied on every reconcile (like ``ListSpec``).
public struct OutlineSpec {
    /// One node in the tree. `children` empty ⇒ a leaf. `selectable` false ⇒ a non-selecting header (a
    /// group title); selecting it just expands/collapses.
    public struct Node {
        public let id: AnyHashable
        public let title: String
        public let children: [Node]
        public let selectable: Bool
        public init(id: AnyHashable, title: String, children: [Node] = [], selectable: Bool = true) {
            self.id = id; self.title = title; self.children = children; self.selectable = selectable
        }
        /// A stable string key for toolkit bookkeeping (native item identity / row maps).
        public var key: String { "\(id.base)" }
    }
    public let roots: [Node]
    public var selectedID: AnyHashable?
    public var onSelect: @MainActor (AnyHashable?) -> Void

    public init(roots: [Node], selectedID: AnyHashable? = nil,
                onSelect: @escaping @MainActor (AnyHashable?) -> Void = { _ in }) {
        self.roots = roots
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    /// A cheap signature of the tree's shape + row titles. A toolkit rebuilds its native tree only when
    /// this changes, so an unrelated reconcile doesn't collapse the user's expansion state or disturb an
    /// in-progress selection. (Selection itself is carried separately in `selectedID`.)
    public var structureSignature: String {
        func sig(_ nodes: [Node]) -> String {
            nodes.map { "\($0.key)|\($0.title)|\($0.selectable ? 1 : 0)(\(sig($0.children)))" }.joined(separator: ",")
        }
        return sig(roots)
    }

    /// The tree flattened to a pre-order list of `(node, depth)` pairs, for toolkits whose tree widget is
    /// populated row-by-row with an explicit indentation level (e.g. Qt `QTreeWidget` items, GTK rows).
    public func flattened() -> [(node: Node, depth: Int)] {
        var out: [(Node, Int)] = []
        func walk(_ nodes: [Node], _ depth: Int) {
            for node in nodes { out.append((node, depth)); walk(node.children, depth + 1) }
        }
        walk(roots, 0)
        return out
    }
}

/// A struct-of-optionals describing widget properties. The reconciler diffs old vs. new and the
/// toolkit applies only the fields that are present.
public struct WidgetPatch: Equatable {
    public var text: String?
    public var title: String?
    public var spacing: Double?
    /// Current text content of a text field.
    public var value: String?
    /// Placeholder text shown when a text field is empty.
    public var placeholder: String?
    /// Current numeric value of a slider.
    public var doubleValue: Double?
    /// Current on/off state of a `.toggle`.
    public var boolValue: Bool?
    /// Inclusive bounds of a slider.
    public var minValue: Double?
    public var maxValue: Double?
    /// Text/foreground color (`.foregroundStyle`).
    public var foregroundColor: Color?
    /// Background fill behind the widget (`.background`).
    public var backgroundColor: Color?
    /// Text font — family and size (`.font`).
    public var font: Font?
    /// Weight override applied on top of `font` (or the default font), from `.fontWeight`.
    public var fontWeight: Font.Weight?
    /// Progress fraction (0...1) for a `.progress` widget; `nil` means indeterminate (animated).
    public var progressValue: Double?
    /// Accessibility information, applied to the toolkit's native accessibility API by the toolkit.
    public var accessibilityLabel: String?
    public var accessibilityValue: String?
    public var accessibilityHint: String?
    public var accessibilityIdentifier: String?
    public var accessibilityHidden: Bool?
    public var accessibilityTraits: AccessibilityTraits?

    public init(text: String? = nil, title: String? = nil, spacing: Double? = nil,
                value: String? = nil, placeholder: String? = nil,
                doubleValue: Double? = nil, boolValue: Bool? = nil,
                minValue: Double? = nil, maxValue: Double? = nil,
                foregroundColor: Color? = nil, backgroundColor: Color? = nil,
                font: Font? = nil, fontWeight: Font.Weight? = nil) {
        self.text = text
        self.title = title
        self.spacing = spacing
        self.value = value
        self.placeholder = placeholder
        self.doubleValue = doubleValue
        self.boolValue = boolValue
        self.minValue = minValue
        self.maxValue = maxValue
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.font = font
        self.fontWeight = fontWeight
    }
}

/// A value-type snapshot of one node in the render tree, keyed by a stable ``id``. This is the
/// toolkit-agnostic intermediate representation the reconciler diffs.
public struct RenderNode {
    public let id: String
    public let kind: WidgetKind
    public var patch: WidgetPatch
    public var children: [RenderNode]
    /// Primary action for interactive widgets (e.g. a button click). Not part of equality.
    public var action: (@MainActor () -> Void)?
    /// Text-change handler for editable widgets (e.g. a text field). Not part of equality.
    public var onChange: (@MainActor (String) -> Void)?
    /// Numeric-change handler for value widgets (e.g. a slider). Not part of equality.
    public var onChangeDouble: (@MainActor (Double) -> Void)?
    /// Boolean-change handler for `.toggle` widgets. Not part of equality.
    public var onChangeBool: (@MainActor (Bool) -> Void)?
    /// Lazy list configuration for `.list` nodes. Not part of equality.
    public var list: ListSpec?
    /// Vector-drawing configuration for `.shape` nodes. Not part of equality.
    public var shape: ShapeSpec?
    /// Drop-down contents for `.menu` nodes. Not part of equality.
    public var menu: MenuContent?
    /// Selection-popup configuration for `.picker` nodes. Not part of equality.
    public var picker: PickerSpec?
    /// Date/time configuration for `.datePicker` nodes. Not part of equality.
    public var datePicker: DatePickerSpec?
    /// Tree configuration for `.outline`/`.sidebarOutline` nodes. Not part of equality.
    public var outline: OutlineSpec?
    /// Image configuration for `.image` nodes. Not part of equality.
    public var image: ImageSpec?
    /// Tab configuration for `.tabView` nodes. Not part of equality.
    public var tabs: TabSpec?
    /// Identity value from `.tag(_:)`, read by a `Picker` to match its selection. Not rendered.
    public var tag: AnyHashable?
    /// Tab title from `.tabItem`, read by a ``TabView`` to build its tab bar. Not rendered directly.
    public var tabLabel: String?
    /// How the framework-owned layout engine sizes and positions this node (and its children).
    public var layout: LayoutInfo
    /// For a `.geometry` or `.scroll` node: called by the layout engine with the node's laid-out
    /// (viewport) size, so a ``GeometryReader``/``ScrollView`` can feed it back into its content. Not
    /// part of equality.
    public var onGeometry: (@MainActor (CGSize) -> Void)?
    /// For a `.scroll` node: called by the toolkit with the current scroll offset when the user scrolls,
    /// so virtualized content can re-materialize the visible window. Not part of equality.
    public var onScroll: (@MainActor (CGSize) -> Void)?
    /// For a `.lazyStack` node: called by the layout engine with a materialized row's measured extent, so
    /// the lazy stack can refine its (uniform) row-size estimate. Not part of equality.
    public var onRowExtent: (@MainActor (Double) -> Void)?
    /// For a `.lazyStack` node: called by the layout engine with the node's top offset within the enclosing
    /// scroll's content, so the visible-row window is computed relative to the lazy stack (not the scroll
    /// origin) when it sits below other content. Not part of equality.
    public var onContentOrigin: (@MainActor (Double) -> Void)?

    public init(id: String, kind: WidgetKind, patch: WidgetPatch = WidgetPatch(),
                children: [RenderNode] = [], action: (@MainActor () -> Void)? = nil,
                onChange: (@MainActor (String) -> Void)? = nil,
                onChangeDouble: (@MainActor (Double) -> Void)? = nil,
                onChangeBool: (@MainActor (Bool) -> Void)? = nil,
                list: ListSpec? = nil, shape: ShapeSpec? = nil,
                menu: MenuContent? = nil, picker: PickerSpec? = nil, datePicker: DatePickerSpec? = nil,
                tag: AnyHashable? = nil,
                outline: OutlineSpec? = nil, image: ImageSpec? = nil, tabs: TabSpec? = nil,
                layout: LayoutInfo = LayoutInfo(), onGeometry: (@MainActor (CGSize) -> Void)? = nil,
                onScroll: (@MainActor (CGSize) -> Void)? = nil,
                onRowExtent: (@MainActor (Double) -> Void)? = nil,
                onContentOrigin: (@MainActor (Double) -> Void)? = nil) {
        self.id = id
        self.kind = kind
        self.patch = patch
        self.children = children
        self.action = action
        self.onChange = onChange
        self.onChangeDouble = onChangeDouble
        self.onChangeBool = onChangeBool
        self.list = list
        self.shape = shape
        self.menu = menu
        self.picker = picker
        self.datePicker = datePicker
        self.outline = outline
        self.image = image
        self.tabs = tabs
        self.tag = tag
        self.layout = layout
        self.onGeometry = onGeometry
        self.onScroll = onScroll
        self.onRowExtent = onRowExtent
        self.onContentOrigin = onContentOrigin
    }
}

/// One segment of a view's identity. `index` is structural (position-based, the default); `key` is
/// explicit and position-independent (a `ForEach` element id or `.id(_:)` value) so a keyed node keeps
/// its identity when its siblings reorder; `branch` distinguishes the arms of an `if`/`else` so
/// switching arms is a fresh identity (state resets) — all mirroring how SwiftUI assigns identity.
enum IDComponent: Hashable {
    case index(Int)
    case key(AnyHashable)
    case branch(Int)

    var token: String {
        switch self {
        case .index(let i): return "\(i)"
        case .key(let k): return "k\(String(describing: k))"
        case .branch(let b): return "b\(b)"
        }
    }
}

/// Carries the identity path down the view tree during evaluation. The joined path is the node's
/// stable identity for reconciliation — stable across re-evaluation, and (for keyed nodes) stable
/// across reordering of their siblings.
struct RenderContext {
    var path: [IDComponent]
    var id: String { path.map(\.token).joined(separator: ".") }
    func appending(_ index: Int) -> RenderContext { RenderContext(path: path + [.index(index)]) }
    func appendingKey(_ key: AnyHashable) -> RenderContext { RenderContext(path: path + [.key(key)]) }
    func appendingBranch(_ branch: Int) -> RenderContext { RenderContext(path: path + [.branch(branch)]) }
}

/// A view that produces a ``RenderNode`` directly rather than via a `body`.
@MainActor
protocol PrimitiveView {
    func makeNode(_ context: RenderContext) -> RenderNode
}

/// Recursively evaluate a view into render nodes, reading any `@State` it touches (which records
/// dependency edges on the enclosing rule attribute) and assigning each node its identity (§IDComponent).
func evaluate(_ view: any View, _ context: RenderContext) -> [RenderNode] {
    if let primitive = view as? PrimitiveView {
        return [primitive.makeNode(context)]
    }
    if let forEach = view as? AnyForEach {
        // Each element gets explicit, position-independent identity from its key, so reordering the
        // data reuses (rather than rebuilds) the elements' widgets and preserves their state.
        var nodes: [RenderNode] = []
        for element in forEach.forEachChildren() {
            nodes += evaluate(element.view, context.appendingKey(element.key))
        }
        return nodes
    }
    if let conditional = view as? AnyConditionalContent {
        // The branch tag makes the two arms distinct identities → switching arms resets state.
        return evaluate(conditional.conditionalContent, context.appendingBranch(conditional.conditionalBranch))
    }
    if let idView = view as? AnyIDView {
        return evaluate(idView.idContent, context.appendingKey(idView.idValue))
    }
    if let envWriter = view as? AnyEnvironmentWriter {
        // Bracket the ambient environment: descendants of this subtree see the injected object(s);
        // siblings (evaluated after the defer restores) do not.
        let saved = EnvironmentStore.current
        var environment = saved
        envWriter.writeEnvironment(&environment)
        EnvironmentStore.current = environment
        defer { EnvironmentStore.current = saved }
        return evaluate(envWriter.environmentContent, context.appending(0))
    }
    if let tuple = view as? AnyTupleView {
        var nodes: [RenderNode] = []
        for (index, child) in tuple.childViews.enumerated() {
            nodes += evaluate(child, context.appending(index))
        }
        return nodes
    }
    if view is EmptyView {
        return []
    }
    return evaluate(view.body, context.appending(0))
}
