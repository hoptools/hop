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
    /// A color chooser (``ColorPicker``), backed by the toolkit's native control (NSColorWell /
    /// GtkColorButton / a QColorDialog button). Carries a ``ColorPickerSpec``.
    case colorPicker
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

/// Preferences a node contributes UP the tree (mirroring SwiftUI's preference system), attached by
/// `.toolbar` / `.preferredColorScheme` / `.navigationTitle` / `.navigationDestination`.
///
/// Carrying preferences as node data — rather than via the old global side-effect collectors — is what
/// makes them correct under fine-grained reactivity: a memoized (un-re-run) subtree still carries its
/// preferences in its cached nodes, so a tree walk after evaluation collects them. A global collector
/// would silently lose a cached subtree's contributions. (See `project_hopui_finegrained_reactivity`.)
public struct NodePreferences {
    /// `.preferredColorScheme(_:)` — window appearance. Outermost wins (first found in pre-order).
    public var preferredColorScheme: ColorScheme?
    /// `.toolbar { }` items, concatenated in pre-order across the tree.
    public var toolbar: [ToolbarItemSpec]?
    /// `.navigationTitle(_:)` — consumed by the enclosing `NavigationStack`.
    public var navigationTitle: String?
    /// `.navigationDestination(for:)` builders — consumed by the enclosing `NavigationStack`.
    public var navigationDestinations: [ObjectIdentifier: (AnyHashable) -> any View]?

    public init() {}

    /// Whether this node carries any preference (lets the walk skip empty nodes cheaply).
    var isEmpty: Bool {
        preferredColorScheme == nil && toolbar == nil && navigationTitle == nil && navigationDestinations == nil
    }

    /// Combine with an OUTER set of preferences (e.g. those a wrapping modifier accumulated on a composite
    /// reference): outer wins for the single-valued ones, outer items come first for the toolbar.
    func merging(_ outer: NodePreferences) -> NodePreferences {
        var result = self
        if let scheme = outer.preferredColorScheme { result.preferredColorScheme = scheme }
        if let items = outer.toolbar { result.toolbar = items + (result.toolbar ?? []) }
        if let title = outer.navigationTitle { result.navigationTitle = title }
        if let dests = outer.navigationDestinations {
            result.navigationDestinations = dests.merging(result.navigationDestinations ?? [:]) { o, _ in o }
        }
        return result
    }
}

extension WidgetPatch {
    /// Overlay every field `other` sets (non-nil) onto `self`. Used to transfer patch state a wrapping
    /// modifier (e.g. `.accessibilityLabel`) accumulated on a composite reference onto its resolved node.
    mutating func overlay(_ other: WidgetPatch) {
        if let v = other.text { text = v }
        if let v = other.title { title = v }
        if let v = other.spacing { spacing = v }
        if let v = other.value { value = v }
        if let v = other.placeholder { placeholder = v }
        if let v = other.doubleValue { doubleValue = v }
        if let v = other.boolValue { boolValue = v }
        if let v = other.minValue { minValue = v }
        if let v = other.maxValue { maxValue = v }
        if let v = other.foregroundColor { foregroundColor = v }
        if let v = other.backgroundColor { backgroundColor = v }
        if let v = other.font { font = v }
        if let v = other.fontWeight { fontWeight = v }
        if let v = other.progressValue { progressValue = v }
        if let v = other.accessibilityLabel { accessibilityLabel = v }
        if let v = other.accessibilityValue { accessibilityValue = v }
        if let v = other.accessibilityHint { accessibilityHint = v }
        if let v = other.accessibilityIdentifier { accessibilityIdentifier = v }
        if let v = other.accessibilityHidden { accessibilityHidden = v }
        if let v = other.accessibilityTraits { accessibilityTraits = v }
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
    /// Color configuration for `.colorPicker` nodes. Not part of equality.
    public var colorPicker: ColorPickerSpec?
    /// File-open-panel presentation attached via `.fileImporter`. Not part of equality.
    public var fileImporter: FileImporterSpec?
    /// File-save-panel presentation attached via `.fileExporter`. Not part of equality.
    public var fileExporter: FileExporterSpec?
    /// Tree configuration for `.outline`/`.sidebarOutline` nodes. Not part of equality.
    public var outline: OutlineSpec?
    /// Image configuration for `.image` nodes. Not part of equality.
    public var image: ImageSpec?
    /// Tab configuration for `.tabView` nodes. Not part of equality.
    public var tabs: TabSpec?
    /// Preferences this node contributes up the tree (`.toolbar`/`.preferredColorScheme`/
    /// `.navigationTitle`/`.navigationDestination`). Collected by a tree walk. Not part of equality.
    public var preferences: NodePreferences?
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
    /// Internal: a placeholder standing in for a composite (user) view's subtree. `evaluate` emits these
    /// at composite boundaries instead of reading the child's body — so a parent body NEVER depends on a
    /// child's value, and a descendant change can't force its ancestors to re-run. ``resolveRenderTree``
    /// replaces each with `read(compositeRef.body)`, re-running only the bodies that actually changed.
    /// (See `project_hopui_finegrained_reactivity`.) Always nil in a resolved tree (what reconcile/layout see).
    var compositeRef: CompositeNode?
    /// The open widget component — the sole description the reconciler and layout engine use (realize/update
    /// via the toolkit's component path, role via `component.role`, reuse-match via `component.widgetKey`).
    /// Views pass one explicitly; internally-constructed nodes get one derived from `kind` (see the init).
    public var component: any WidgetComponent

    /// Reuse identity for the keyed child diff: the component's `widgetKey`. A child is reused across a
    /// reconcile only when this matches — so a `Picker` whose style changed its native widget (different
    /// `widgetKey`) is correctly torn down and recreated rather than reconfigured.
    var reuseSignature: String { "c:\(component.widgetKey.rawValue)" }

    /// The node's widget patch, reading through a migrated leaf component (whose patch now holds the
    /// text/title/value) so content-inspecting primitives (Menu, Picker, Toolbar, OutlineGroup, List,
    /// TabView) keep working during the migration regardless of whether a child is migrated yet.
    var effectivePatch: WidgetPatch { (component as? PrimitiveLeafComponent)?.patch ?? patch }
    /// The node's primary action, read through its leaf component (Button's action lives there).
    var effectiveAction: (@MainActor () -> Void)? { (component as? PrimitiveLeafComponent)?.action }
    /// The node's drop-down menu content, read through its ``MenuComponent`` (for nested submenus).
    var effectiveMenu: MenuContent? { (component as? MenuComponent)?.content }
    /// Set during resolve: a token identifying this subtree's content. Two nodes with the same nonzero
    /// `subtreeRevision` across successive flushes are byte-identical (the resolve pass preserves it only by
    /// reusing the exact cached nodes), so the reconciler and layout engine can safely skip them. `0` means
    /// "unstamped" — never skipped.
    var subtreeRevision: Int = 0

    /// Derives a component for an internally-constructed node (wrappers, the nav bar, fallbacks) from its
    /// kind/patch/handlers — a strangler bridge so every node has a component without rewriting those raw
    /// construction sites. Removed when `WidgetKind` is deleted (those sites then pass a component directly).
    static func derivedComponent(kind: WidgetKind, patch: WidgetPatch,
                                 action: (@MainActor () -> Void)?, onChange: (@MainActor (String) -> Void)?,
                                 onChangeDouble: (@MainActor (Double) -> Void)?, onChangeBool: (@MainActor (Bool) -> Void)?,
                                 layout: LayoutInfo) -> any WidgetComponent {
        switch kind {
        case .vstack, .groupBox:
            return ContainerComponent(WidgetKey(kind == .groupBox ? "groupBox" : "vstack"),
                role: .stack(axis: .vertical, spacing: patch.spacing, alignment: layout.alignment ?? .center))
        case .hstack:
            return ContainerComponent(WidgetKey("hstack"),
                role: .stack(axis: .horizontal, spacing: patch.spacing, alignment: layout.alignment ?? .center))
        case .zstack:
            return ContainerComponent(WidgetKey("zstack"), role: .zstack(alignment: layout.alignment ?? .center))
        case .spacer:
            return ContainerComponent(WidgetKey("spacer"), role: .spacer(minLength: layout.spacerMinLength))
        case .scroll:
            return ContainerComponent(WidgetKey("scroll"), role: .scroll(axis: layout.scrollAxis ?? .vertical))
        case .geometry:
            return ContainerComponent(WidgetKey("geometry"), role: .geometry)
        case .lazyStack:
            if let lazy = layout.lazy {
                return ContainerComponent(WidgetKey("lazyStack"), role: .lazyStack(lazy, alignment: layout.alignment ?? .center))
            }
            return ContainerComponent(WidgetKey("vstack"), role: .stack(axis: .vertical, spacing: nil, alignment: layout.alignment ?? .center))
        case .list, .sidebarList, .outline, .sidebarOutline, .splitView, .tabView:
            return ContainerComponent(WidgetKey("\(kind)"), role: .native)
        default:   // label / button / textField / secureField / slider / toggle / progress / separator / window
            return PrimitiveLeafComponent(WidgetKey("\(kind)"), patch: patch, action: action,
                onChange: onChange, onChangeDouble: onChangeDouble, onChangeBool: onChangeBool)
        }
    }

    public init(id: String, kind: WidgetKind, patch: WidgetPatch = WidgetPatch(),
                children: [RenderNode] = [], action: (@MainActor () -> Void)? = nil,
                onChange: (@MainActor (String) -> Void)? = nil,
                onChangeDouble: (@MainActor (Double) -> Void)? = nil,
                onChangeBool: (@MainActor (Bool) -> Void)? = nil,
                list: ListSpec? = nil, shape: ShapeSpec? = nil,
                menu: MenuContent? = nil, picker: PickerSpec? = nil, datePicker: DatePickerSpec? = nil,
                colorPicker: ColorPickerSpec? = nil,
                fileImporter: FileImporterSpec? = nil, fileExporter: FileExporterSpec? = nil,
                tag: AnyHashable? = nil,
                outline: OutlineSpec? = nil, image: ImageSpec? = nil, tabs: TabSpec? = nil,
                preferences: NodePreferences? = nil, component: (any WidgetComponent)? = nil,
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
        self.colorPicker = colorPicker
        self.fileImporter = fileImporter
        self.fileExporter = fileExporter
        self.outline = outline
        self.image = image
        self.tabs = tabs
        self.preferences = preferences
        // Every node carries a component. Views pass one explicitly; the remaining internally-constructed
        // nodes (wrappers, the nav bar, fallbacks) get one derived from their kind/patch/handlers here, so
        // the reconciler and layout engine have a single (component) path. (The legacy `kind` is retained
        // only as the derivation key + each backend's native-creation key until the final WidgetKind removal.)
        self.component = component ?? RenderNode.derivedComponent(
            kind: kind, patch: patch, action: action, onChange: onChange,
            onChangeDouble: onChangeDouble, onChangeBool: onChangeBool, layout: layout)
        self.tag = tag
        self.layout = layout
        self.onGeometry = onGeometry
        self.onScroll = onScroll
        self.onRowExtent = onRowExtent
        self.onContentOrigin = onContentOrigin
    }
}

extension RenderNode {
    /// Whether any wrapping-modifier state accumulated on this (composite-reference) node and so must be
    /// transferred onto the resolved subtree. Lets resolve skip the transfer (and an extra revision bump)
    /// for the common case of a bare composite with no surrounding modifiers.
    var hasWrapperState: Bool {
        !layout.modifiers.isEmpty || preferences != nil || tag != nil || tabLabel != nil
            || fileImporter != nil || fileExporter != nil || patch != WidgetPatch()
    }

    /// Overlay onto `self` the modifier state a wrapping modifier accumulated on a composite reference
    /// (which ``resolveRenderTree`` is replacing with `self`): outer layout modifiers (appended after the
    /// node's own, so they apply outermost), merged preferences, tag/tabItem, file presentations, and any
    /// patch fields the modifier set. This makes `.frame`/`.toolbar`/`.tag`/… on a composite behave
    /// exactly as on a primitive — the attached state lands on the composite's first rendered node.
    mutating func applyWrapperState(from ref: RenderNode) {
        if !ref.layout.modifiers.isEmpty { layout.modifiers += ref.layout.modifiers }
        if let refPrefs = ref.preferences { preferences = (preferences ?? NodePreferences()).merging(refPrefs) }
        if let t = ref.tag { tag = t }
        if let tl = ref.tabLabel { tabLabel = tl }
        if let fi = ref.fileImporter { fileImporter = fi }
        if let fe = ref.fileExporter { fileExporter = fe }
        patch.overlay(ref.patch)
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
        // Derive a retained environment attribute for this subtree (pushed with setValueIfChanged, so
        // descendants re-run only when the derived environment actually changes). Bracket it so leaves
        // and child composites read it through the graph; siblings (after the defer) see the parent env.
        let saved = EnvironmentStore.currentAttr
        if let viewGraph = GraphContext.viewGraph {
            EnvironmentStore.currentAttr = viewGraph.derivedEnvironment(for: context.id) {
                envWriter.writeEnvironment(&$0)
            }
        }
        defer { EnvironmentStore.currentAttr = saved }
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
    // A composite (user) view: route through the retained view graph. The node owns a memoized `body`
    // rule keyed by identity; prop-diff (inside `composite(for:)`) decides whether new incoming props
    // force it to re-evaluate. We emit a REFERENCE rather than reading the body here, so the enclosing
    // body never depends on this child's value — a descendant change can't force its ancestors to re-run.
    // The reference is expanded later by `resolveRenderTree` (which re-runs only the bodies that changed).
    guard let viewGraph = GraphContext.viewGraph else {
        return evaluate(view.body, context.appending(0))   // defensive: no view graph installed
    }
    let node = viewGraph.composite(for: view, id: context.id, context: context)
    var ref = RenderNode(id: node.id, kind: .vstack)
    ref.compositeRef = node
    return [ref]
}
