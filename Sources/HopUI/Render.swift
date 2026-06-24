// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

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
    /// Transparency 0...1 (`.opacity`); nil = fully opaque. Applied to the widget (and its subtree).
    public var opacity: Double?
    /// Enabled state (`.disabled`); nil/true = interactive, false = dimmed + non-interactive. Applied to the
    /// widget; on GTK/Qt/WinUI the toolkit's hierarchical enabled state cascades it to descendant controls.
    public var isEnabled: Bool?
    /// Italic / monospaced text traits (`.italic()` / `.monospaced()`). Separate from `font` so they apply on
    /// top of the resolved (possibly default-size) font without forcing a size.
    public var italic: Bool?
    public var monospaced: Bool?
    /// Multi-line text alignment (`.multilineTextAlignment`); nil = the toolkit's default. Paragraph-level.
    public var textAlignment: TextAlignment?

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
    /// The resolved navigation chrome (title) an enclosing `NavigationStack` publishes to the window so
    /// the toolkit can render it natively. Collected by `collectWindowPreferences` (first in pre-order wins).
    public var navigationBar: NavigationBarSpec?

    public init() {}

    /// Whether this node carries any preference (lets the walk skip empty nodes cheaply).
    var isEmpty: Bool {
        preferredColorScheme == nil && toolbar == nil && navigationTitle == nil
            && navigationDestinations == nil && navigationBar == nil
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
        if let nb = outer.navigationBar { result.navigationBar = nb }
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
        if let v = other.opacity { opacity = v }
        if let v = other.isEnabled { isEnabled = v }
        if let v = other.italic { italic = v }
        if let v = other.monospaced { monospaced = v }
        if let v = other.textAlignment { textAlignment = v }
    }
}

/// A value-type snapshot of one node in the render tree, keyed by a stable ``id``. This is the
/// toolkit-agnostic intermediate representation the reconciler diffs.
public struct RenderNode {
    public let id: String
    public var patch: WidgetPatch
    public var children: [RenderNode]
    /// File-open-panel presentation attached via `.fileImporter`. Not part of equality.
    public var fileImporter: FileImporterSpec?
    /// File-save-panel presentation attached via `.fileExporter`. Not part of equality.
    public var fileExporter: FileExporterSpec?
    /// Native-alert presentation attached via `.alert`. Not part of equality.
    public var alert: AlertSpec?
    /// Modal-sheet presentation attached via `.sheet` (its `content` is the resolved sheet body). Not part of equality.
    public var sheet: SheetSpec?
    /// A `Button`'s semantic role from `Button(_:role:)`, read by ``Alert`` to style its buttons. Not rendered.
    public var buttonRole: ButtonRole?
    /// Preferences this node contributes up the tree (`.toolbar`/`.preferredColorScheme`/
    /// `.navigationTitle`/`.navigationDestination`). Collected by a tree walk. Not part of equality.
    public var preferences: NodePreferences?
    /// Identity value from `.tag(_:)`, read by a `Picker` to match its selection. Not rendered.
    public var tag: AnyHashable?
    /// Tab title from `.tabItem`, read by a ``TabView`` to build its tab bar. Not rendered directly.
    public var tabLabel: String?
    /// Grid cell metadata, read by the enclosing ``Grid``'s layout. `.gridCellColumns(_:)` (column span),
    /// `.gridColumnAlignment(_:)` (whole-column H-alignment), `.gridCellAnchor(_:)` (UnitPoint within the
    /// cell), `.gridCellUnsizedAxes(_:)` (axes on which the cell uses its intrinsic size, not the cell's).
    public var gridCellColumns: Int?
    public var gridColumnAlignment: HorizontalAlignment?
    public var gridCellAnchor: UnitPoint?
    public var gridCellUnsizedAxes: Axis.Set?
    /// How the framework-owned layout engine sizes and positions this node (and its children).
    public var layout: LayoutInfo
    /// For a `.geometry` or `.scroll` node: called by the layout engine with the node's laid-out
    /// (viewport) size, so a ``GeometryReader``/``ScrollView`` can feed it back into its content. Not
    /// part of equality.
    public var onGeometry: (@MainActor (CGSize) -> Void)?
    /// For a `.scroll` node: called by the toolkit with the current scroll offset when the user scrolls,
    /// so virtualized content can re-materialize the visible window. Not part of equality.
    public var onScroll: (@MainActor (CGSize) -> Void)?
    /// Tap-gesture handler attached via `.onTapGesture`; the toolkit installs a native tap recognizer on
    /// this node's widget that invokes it. Not part of equality.
    public var onTap: TapGestureSpec?
    /// Long-press / hover / drag / magnify / rotate handlers attached via `.onLongPressGesture` / `.onHover`
    /// / `.gesture(DragGesture()/MagnifyGesture()/RotateGesture())`. Each toolkit installs the matching
    /// native recognizer on this node's widget. Not part of equality; default nil so the init needn't set them.
    public var onLongPress: LongPressGestureSpec?
    public var onHover: (@MainActor (Bool) -> Void)?
    public var dragGesture: DragGestureSpec?
    public var magnifyGesture: MagnifyGestureSpec?
    public var rotateGesture: RotateGestureSpec?
    /// Submit handler attached via `.onSubmit`; the toolkit fires it when the user presses Return in this
    /// node's text field (`.textField`/`.secureField`). Not part of equality.
    public var onSubmit: (@MainActor () -> Void)?
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
    /// Every node carries one (views and internal wrappers alike pass it explicitly).
    public var component: any WidgetComponent

    /// Reuse identity for the keyed child diff: the component's `widgetKey`. A child is reused across a
    /// reconcile only when this matches — so a `Picker` whose style changed its native widget (different
    /// `widgetKey`) is correctly torn down and recreated rather than reconfigured. Grid cell metadata
    /// (span/alignment/anchor/unsized axes) is deliberately NOT part of it: it only feeds the layout
    /// engine's frame math (recomputed every pass), never the choice of native widget — so a span change
    /// reconfigures the cell in place and preserves its native state (text cursor, focus, scroll offset).
    var reuseSignature: String { "c:\(component.widgetKey.rawValue)" }

    /// The node's widget patch, read through its leaf component (whose patch holds the text/title/value),
    /// so content-inspecting primitives (Menu, Picker, Toolbar, OutlineGroup, List, TabView) can read it.
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

    public init(id: String, component: any WidgetComponent, patch: WidgetPatch = WidgetPatch(),
                children: [RenderNode] = [],
                fileImporter: FileImporterSpec? = nil, fileExporter: FileExporterSpec? = nil,
                tag: AnyHashable? = nil,
                preferences: NodePreferences? = nil,
                layout: LayoutInfo = LayoutInfo(), onGeometry: (@MainActor (CGSize) -> Void)? = nil,
                onScroll: (@MainActor (CGSize) -> Void)? = nil, onTap: TapGestureSpec? = nil,
                onRowExtent: (@MainActor (Double) -> Void)? = nil,
                onContentOrigin: (@MainActor (Double) -> Void)? = nil) {
        self.id = id
        self.component = component
        self.patch = patch
        self.children = children
        self.fileImporter = fileImporter
        self.fileExporter = fileExporter
        self.preferences = preferences
        self.tag = tag
        self.layout = layout
        self.onGeometry = onGeometry
        self.onScroll = onScroll
        self.onTap = onTap
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
            || fileImporter != nil || fileExporter != nil || alert != nil || sheet != nil || onTap != nil
            || patch != WidgetPatch()
            || onLongPress != nil || onHover != nil || dragGesture != nil || magnifyGesture != nil
            || rotateGesture != nil || onSubmit != nil
            || gridCellColumns != nil || gridColumnAlignment != nil || gridCellAnchor != nil
            || gridCellUnsizedAxes != nil
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
        if let gc = ref.gridCellColumns { gridCellColumns = gc }
        if let ga = ref.gridColumnAlignment { gridColumnAlignment = ga }
        if let gan = ref.gridCellAnchor { gridCellAnchor = gan }
        if let gu = ref.gridCellUnsizedAxes { gridCellUnsizedAxes = gu }
        if let fi = ref.fileImporter { fileImporter = fi }
        if let fe = ref.fileExporter { fileExporter = fe }
        if let al = ref.alert { alert = al }
        if let sh = ref.sheet { sheet = sh }
        if let ot = ref.onTap { onTap = ot }
        if let lp = ref.onLongPress { onLongPress = lp }
        if let hv = ref.onHover { onHover = hv }
        if let dg = ref.dragGesture { dragGesture = dg }
        if let mg = ref.magnifyGesture { magnifyGesture = mg }
        if let rg = ref.rotateGesture { rotateGesture = rg }
        if let os = ref.onSubmit { onSubmit = os }
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

/// A view that produces a ``RenderNode`` directly rather than via a `body`. Internal — built-in views
/// (Text, Button, …) conform to it. The public extensibility seam is ``HopRepresentable``.
@MainActor
protocol PrimitiveView {
    func makeNode(_ context: RenderContext) -> RenderNode
}

/// The public seam for **external packages** to add a new native widget — HopUI's cross-toolkit analog of
/// SwiftUI's `NSViewRepresentable`. Conform a `View` to it and return a ``WidgetComponent`` describing the
/// widget; HopUI builds the render node (giving it identity) and each backend realizes the component via
/// its registered renderer or the component's self-hosted `makeNative`. The package never touches
/// `RenderContext`, render nodes, or backend `Handle`s. (See the toolkit-extensibility plan.)
@MainActor
public protocol HopRepresentable: View where Body == Never {
    /// The toolkit-agnostic description of this view's native widget (a custom ``WidgetComponent``).
    var component: any WidgetComponent { get }
}

public extension HopRepresentable {
    var body: Never { fatalError("a HopRepresentable produces a component, not a body") }
}

/// Recursively evaluate a view into render nodes, reading any `@State` it touches (which records
/// dependency edges on the enclosing rule attribute) and assigning each node its identity (§IDComponent).
func evaluate(_ view: any View, _ context: RenderContext) -> [RenderNode] {
    if let primitive = view as? PrimitiveView {
        return [primitive.makeNode(context)]
    }
    // External widgets (a `HopRepresentable`) supply only their component; HopUI assigns identity here.
    if let representable = view as? any HopRepresentable {
        return [RenderNode(id: context.id, component: representable.component)]
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
    var ref = RenderNode(id: node.id, component: ContainerComponent.vstack())
    ref.compositeRef = node
    return [ref]
}
