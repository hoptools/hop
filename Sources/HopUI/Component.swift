// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The open, component-based widget system. A `WidgetComponent` is a toolkit-agnostic description of one
// native widget; each backend renders it via an open registry (built-ins) or the component's own
// self-hosted code (third-party packages), with no closed `WidgetKind` enum to extend. This is the
// extensibility seam: external packages add widgets — even ones whose native implementation varies by
// style — without modifying `hop`. (See the toolkit-extensibility plan.) Every `RenderNode` carries a
// `component`; the reconciler and layout engine describe a widget solely through it.

/// Identifies a toolkit at runtime. String-backed so a future external toolkit gets its own id without
/// editing `hop`. Each backend exposes its id via `RenderToolkit.toolkitID`.
public struct ToolkitID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let appKit = ToolkitID("appkit")
    public static let gtk4 = ToolkitID("gtk4")
    public static let qt = ToolkitID("qt")
    public static let winUI = ToolkitID("winui")
    public static let mock = ToolkitID("mock")
}

/// The **implementation identity** of a widget — the dispatch + reuse key. CRITICAL CONVENTION: this is
/// the identity of the *native widget*, not the logical view. Anything that selects a different native
/// widget (e.g. a `Picker`'s `.menu` vs `.segmented` style) MUST be part of the key, so that a change
/// recreates the widget (the reconciler reuses a handle only when the key matches) rather than trying to
/// reconfigure an incompatible one. Config that `update` can apply in place stays in the component's
/// payload, not the key.
public struct WidgetKey: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// The keys for HopUI's built-in widgets, so call sites reference `.button` (etc.) instead of repeating
/// string literals. Third-party components define their own keys the same way (an extension on `WidgetKey`).
public extension WidgetKey {
    static let window = WidgetKey("window")
    static let vstack = WidgetKey("vstack")
    static let hstack = WidgetKey("hstack")
    static let zstack = WidgetKey("zstack")
    static let spacer = WidgetKey("spacer")
    static let scroll = WidgetKey("scroll")
    static let geometry = WidgetKey("geometry")
    static let lazyStack = WidgetKey("lazyStack")
    static let grid = WidgetKey("grid")
    static let gridRow = WidgetKey("gridRow")
    static let groupBox = WidgetKey("groupBox")
    static let label = WidgetKey("label")
    static let button = WidgetKey("button")
    static let textField = WidgetKey("textField")
    static let secureField = WidgetKey("secureField")
    static let textEditor = WidgetKey("textEditor")   // multiline, scrollable, space-filling editor
    static let slider = WidgetKey("slider")
    static let toggle = WidgetKey("toggle")
    static let progress = WidgetKey("progress")
    static let separator = WidgetKey("separator")
    static let shape = WidgetKey("shape")
    static let menu = WidgetKey("menu")
    static let picker = WidgetKey("picker")   // the base popup; per-style keys come from picker(_:)
    static let datePicker = WidgetKey("datePicker")
    static let colorPicker = WidgetKey("colorPicker")
    static let image = WidgetKey("image")
    static let list = WidgetKey("list")
    static let sidebarList = WidgetKey("sidebarList")
    static let outline = WidgetKey("outline")
    static let sidebarOutline = WidgetKey("sidebarOutline")
    static let splitView = WidgetKey("splitView")
    static let tabView = WidgetKey("tabView")
}

/// How the layout engine treats a component (replaces the `WidgetKind` switch in `LayoutEngine`). A
/// component computes its own role — so a single view type can be a leaf for one style and a native
/// composite for another. The callback-carrying cases (scroll/geometry/lazyStack) are added as those
/// components migrate (Phase 6).
public enum WidgetRole {
    /// Sized by the toolkit's intrinsic measurement (text, controls, non-resizable images).
    case leaf
    /// Greedily takes the space offered along both axes (embeds like a web view or video surface).
    case fill
    /// A native composite that positions its own internals (list, tab view, a renderer-built group).
    case native
    /// A flexible gap whose extent the enclosing stack decides.
    case spacer(minLength: Double)
    /// A vertical/horizontal stack laid out by the engine.
    case stack(axis: Axis, spacing: Double?, alignment: Alignment)
    /// Children overlaid and aligned within the stack's bounds.
    case zstack(alignment: Alignment)
    /// A scroll viewport along an axis (its content laid out unbounded along that axis).
    case scroll(axis: Axis)
    /// A geometry reader: reports its laid-out size back to its content.
    case geometry
    /// A virtualizing lazy stack: only the visible window of rows is materialized.
    case lazyStack(LazyInfo, alignment: Alignment)
    /// A non-lazy column-aligned `Grid`: columns are sized to the widest cell across rows. Children are
    /// `.gridRow` containers (and/or loose full-span views); cells are positioned by the grid (2-pass).
    case grid(GridConfig)
    /// A `GridRow` — a marker container the enclosing `.grid` positions through (its cells are the grid's
    /// real layout units). Outside a Grid it degrades to a horizontal stack.
    case gridRow(VerticalAlignment?)
}

/// Configuration for a ``Grid`` carried on its role: the content alignment + the inter-column/-row gaps
/// (nil → the framework default).
public struct GridConfig: Equatable, Sendable {
    public var alignment: Alignment
    public var horizontalSpacing: Double?
    public var verticalSpacing: Double?
    public init(alignment: Alignment = .center, horizontalSpacing: Double? = nil, verticalSpacing: Double? = nil) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }
}

/// A toolkit-agnostic description of one native widget — the open replacement for `WidgetKind` + the
/// per-kind `RenderNode` specs. A built-in component is rendered by its backend's registered renderer;
/// a third-party component can instead self-host its native widget via `makeNative` (returning the
/// toolkit's raw native widget — `NSView` / `GtkWidget*` / `QWidget*`), keeping the package decoupled
/// from the backends.
@MainActor
public protocol WidgetComponent {
    /// Dispatch + reuse identity. See ``WidgetKey`` — encode style/config that changes the native widget.
    var widgetKey: WidgetKey { get }
    /// Layout behavior.
    var role: WidgetRole { get }

    /// Self-hosted native widget for `toolkit`, as the toolkit's raw native type (or nil → the backend's
    /// registry is consulted, then a placeholder). Built-ins leave this defaulted and register a renderer.
    func makeNative(_ toolkit: ToolkitID) -> Any?
    /// Update a self-hosted native widget with this component's current state.
    func updateNative(_ native: Any, _ toolkit: ToolkitID)
}

public extension WidgetComponent {
    var role: WidgetRole { .leaf }
    func makeNative(_ toolkit: ToolkitID) -> Any? { nil }
    func updateNative(_ native: Any, _ toolkit: ToolkitID) {}
}

/// The component for HopUI's simple leaf widgets (Text, Button, TextField, SecureField, Slider, Toggle,
/// ProgressView, Divider) — all of which are uniformly "a native widget + a ``WidgetPatch`` + an optional
/// change handler". Each carries a distinct `widgetKey` (so the reconciler never reuses a Button as a
/// Slider) and the backend's leaf renderer creates the native widget for that key and applies the
/// patch + handlers.
public struct PrimitiveLeafComponent: WidgetComponent {
    public let widgetKey: WidgetKey
    public let role: WidgetRole
    public let patch: WidgetPatch
    public let action: (@MainActor () -> Void)?
    public let onChange: (@MainActor (String) -> Void)?
    public let onChangeDouble: (@MainActor (Double) -> Void)?
    public let onChangeBool: (@MainActor (Bool) -> Void)?

    public init(_ key: WidgetKey, role: WidgetRole = .leaf, patch: WidgetPatch = WidgetPatch(),
                action: (@MainActor () -> Void)? = nil,
                onChange: (@MainActor (String) -> Void)? = nil,
                onChangeDouble: (@MainActor (Double) -> Void)? = nil,
                onChangeBool: (@MainActor (Bool) -> Void)? = nil) {
        self.widgetKey = key
        self.role = role
        self.patch = patch
        self.action = action
        self.onChange = onChange
        self.onChangeDouble = onChangeDouble
        self.onChangeBool = onChangeBool
    }
}

/// The open component for a ``Shape``. `spec` is `var` so the shape modifiers (.fill/.stroke/transforms)
/// can mutate it. Public so backend shape renderers can read it.
public struct ShapeComponent: WidgetComponent {
    public var spec: ShapeSpec
    public init(spec: ShapeSpec) { self.spec = spec }
    public var widgetKey: WidgetKey { .shape }
    public var role: WidgetRole { .leaf }   // greediness comes from the renderer's measure (proposal-resolved)
}

/// The component for HopUI's layout containers (VStack/HStack/ZStack/GroupBox). It carries no payload
/// beyond a `widgetKey` and a `role` (which encodes axis/spacing/alignment); children live on the
/// ``RenderNode`` and the backend's container renderer just creates the empty native container — the
/// layout engine arranges the children from `role`.
public struct ContainerComponent: WidgetComponent {
    public let widgetKey: WidgetKey
    public let role: WidgetRole
    public init(_ key: WidgetKey, role: WidgetRole) { self.widgetKey = key; self.role = role }

    /// A plain vertical stack — the common shape of HopUI's internal wrapper nodes (transparent
    /// containers the framework inserts around content). `spacing`/`alignment` flow into the layout role.
    public static func vstack(spacing: Double? = nil, alignment: Alignment = .center) -> ContainerComponent {
        ContainerComponent(.vstack, role: .stack(axis: .vertical, spacing: spacing, alignment: alignment))
    }
    /// A plain horizontal stack.
    public static func hstack(spacing: Double? = nil, alignment: Alignment = .center) -> ContainerComponent {
        ContainerComponent(.hstack, role: .stack(axis: .horizontal, spacing: spacing, alignment: alignment))
    }
    /// A plain overlay (z-)stack.
    public static func zstack(alignment: Alignment = .center) -> ContainerComponent {
        ContainerComponent(.zstack, role: .zstack(alignment: alignment))
    }
    /// A non-lazy column-aligned ``Grid`` container (the engine runs the 2-pass column layout).
    public static func grid(_ config: GridConfig) -> ContainerComponent {
        ContainerComponent(.grid, role: .grid(config))
    }
    /// A ``GridRow`` container the enclosing grid positions through.
    public static func gridRow(_ verticalAlignment: VerticalAlignment?) -> ContainerComponent {
        ContainerComponent(.gridRow, role: .gridRow(verticalAlignment))
    }
}

// MARK: - Native composite components (role `.native`: the widget arranges its own internals)

/// The open component for a flat ``List`` (data-driven, virtualized). `sidebar` selects the source-list
/// styling (in a NavigationSplitView's leading column).
public struct ListComponent: WidgetComponent {
    public let spec: ListSpec
    public let sidebar: Bool
    public init(spec: ListSpec, sidebar: Bool) { self.spec = spec; self.sidebar = sidebar }
    public var widgetKey: WidgetKey { sidebar ? .sidebarList : .list }
    public var role: WidgetRole { .native }
}

/// The open component for a hierarchical ``OutlineGroup`` tree. `spec` is `var` so an enclosing
/// `List(selection:)` can inject selection into it.
public struct OutlineComponent: WidgetComponent {
    public var spec: OutlineSpec
    public let sidebar: Bool
    public init(spec: OutlineSpec, sidebar: Bool) { self.spec = spec; self.sidebar = sidebar }
    public var widgetKey: WidgetKey { sidebar ? .sidebarOutline : .outline }
    public var role: WidgetRole { .native }
}

/// The open component for ``TabView``. Its pages are the node's children; `afterChildren` builds the
/// native tab bar from them + the spec (titles/selection).
public struct TabViewComponent: WidgetComponent {
    public let spec: TabSpec
    public init(spec: TabSpec) { self.spec = spec }
    public var widgetKey: WidgetKey { .tabView }
    public var role: WidgetRole { .native }
}

/// The open component for ``NavigationSplitView`` — a native split whose two children (sidebar, detail)
/// it positions itself.
public struct SplitViewComponent: WidgetComponent {
    public init() {}
    public var widgetKey: WidgetKey { .splitView }
    public var role: WidgetRole { .native }
}

/// A backend's open registry of component renderers, keyed by ``WidgetKey``. A backend registers its
/// built-in renderers here; **third-party packages can register their own** (e.g. `appKit.components`
/// `.register(...)`) — the open replacement for the closed `makeWidget`/`configureX` switch. Generic over
/// the backend's `Handle` so the same machinery serves every toolkit.
@MainActor
public final class ComponentRegistry<Handle: AnyObject> {
    /// Renders one component type on this backend: create the native widget, re-apply state, measure.
    public struct Renderer {
        public let make: (any WidgetComponent) -> Handle
        public let update: (Handle, any WidgetComponent) -> Void
        public let measure: (Handle, any WidgetComponent, ProposedViewSize) -> CGSize
        /// Called after the reconciler has inserted/reconciled this widget's children — for native
        /// composites (e.g. TabView) that build themselves from their now-present children. nil = no-op.
        public let afterChildren: ((Handle, any WidgetComponent) -> Void)?
        public init(make: @escaping (any WidgetComponent) -> Handle,
                    update: @escaping (Handle, any WidgetComponent) -> Void,
                    measure: @escaping (Handle, any WidgetComponent, ProposedViewSize) -> CGSize,
                    afterChildren: ((Handle, any WidgetComponent) -> Void)? = nil) {
            self.make = make; self.update = update; self.measure = measure; self.afterChildren = afterChildren
        }
    }

    private var renderers: [WidgetKey: Renderer] = [:]
    public init() {}

    // An explicit nonisolated deinit avoids synthesizing an *isolating* destructor for this generic
    // MainActor class, which crashes Swift 6.3's SILGen (assertion in emitIsolatingDestructor). The
    // renderer map only releases references, so no main-actor hop is needed. Gated to 6.3+ so the
    // synthesized deinit (fine on the 6.2 toolchain the repo's CI uses elsewhere) is left untouched.
    // Mirrors the same workaround in `State.Box` and `Reconciler`.
    #if compiler(>=6.3)
    nonisolated deinit {}
    #endif

    public func register(_ renderer: Renderer, for key: WidgetKey) { renderers[key] = renderer }
    public func renderer(for key: WidgetKey) -> Renderer? { renderers[key] }
}
