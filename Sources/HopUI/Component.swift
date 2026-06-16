// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The open, component-based widget system. A `WidgetComponent` is a toolkit-agnostic description of one
// native widget; each backend renders it via an open registry (built-ins) or the component's own
// self-hosted code (third-party packages), with no closed `WidgetKind` enum to extend. This is the
// extensibility seam: external packages add widgets — even ones whose native implementation varies by
// style — without modifying `hop`. (See the toolkit-extensibility plan.)
//
// Migration note (strangler): during the migration this lives alongside the legacy `WidgetKind` path.
// A `RenderNode` carries a `component` once migrated; until then it uses `kind` + the per-kind specs.

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
/// Slider) and the backend's leaf renderer applies the patch + handlers. (During the strangler migration
/// each backend's leaf renderer still delegates to the legacy `makeWidget(kind)`; the native code inlines
/// here in the final sweep, when `WidgetKind` is removed.)
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
    public var widgetKey: WidgetKey { WidgetKey("shape") }
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
}

// MARK: - Native composite components (role `.native`: the widget arranges its own internals)

/// The open component for a flat ``List`` (data-driven, virtualized). `sidebar` selects the source-list
/// styling (in a NavigationSplitView's leading column).
public struct ListComponent: WidgetComponent {
    public let spec: ListSpec
    public let sidebar: Bool
    public init(spec: ListSpec, sidebar: Bool) { self.spec = spec; self.sidebar = sidebar }
    public var widgetKey: WidgetKey { WidgetKey(sidebar ? "sidebarList" : "list") }
    public var role: WidgetRole { .native }
}

/// The open component for a hierarchical ``OutlineGroup`` tree. `spec` is `var` so an enclosing
/// `List(selection:)` can inject selection into it.
public struct OutlineComponent: WidgetComponent {
    public var spec: OutlineSpec
    public let sidebar: Bool
    public init(spec: OutlineSpec, sidebar: Bool) { self.spec = spec; self.sidebar = sidebar }
    public var widgetKey: WidgetKey { WidgetKey(sidebar ? "sidebarOutline" : "outline") }
    public var role: WidgetRole { .native }
}

/// The open component for ``TabView``. Its pages are the node's children; `afterChildren` builds the
/// native tab bar from them + the spec (titles/selection).
public struct TabViewComponent: WidgetComponent {
    public let spec: TabSpec
    public init(spec: TabSpec) { self.spec = spec }
    public var widgetKey: WidgetKey { WidgetKey("tabView") }
    public var role: WidgetRole { .native }
}

/// The open component for ``NavigationSplitView`` — a native split whose two children (sidebar, detail)
/// it positions itself.
public struct SplitViewComponent: WidgetComponent {
    public init() {}
    public var widgetKey: WidgetKey { WidgetKey("splitView") }
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

    public func register(_ renderer: Renderer, for key: WidgetKey) { renderers[key] = renderer }
    public func renderer(for key: WidgetKey) -> Renderer? { renderers[key] }
}
