// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// The toolkit-agnostic seam between HopUI and a native widget toolkit.
///
/// A toolkit owns opaque `Handle`s wrapping native widgets and exposes idempotent operations to
/// create, configure, and arrange them. The ``Reconciler`` calls only these operations, so it is
/// entirely free of GTK/AppKit types — which is what lets GTK4, AppKit, and (later) WinUI plug in
/// behind the same protocol.
@MainActor
public protocol RenderToolkit: AnyObject {
    associatedtype Handle: AnyObject

    // MARK: - Open component system (the extensibility seam)

    /// This toolkit's runtime identity (used to dispatch a self-hosted component's `makeNative`).
    static var toolkitID: ToolkitID { get }

    /// Create the native widget for a ``WidgetComponent``: via the backend's registered renderer for
    /// `component.widgetKey`, else the component's self-hosted `makeNative`, else a placeholder. This —
    /// plus ``updateComponent(_:_:)`` and ``measureComponent(_:_:_:)`` — is the *entire* per-widget seam;
    /// new widgets (built-in or third-party) plug in here without changing the protocol.
    func realize(_ component: any WidgetComponent) -> Handle
    /// Re-apply a component's current state to its native widget (reconfigure in place). Called when the
    /// component changed but its `widgetKey` did not (same native widget type).
    func updateComponent(_ handle: Handle, _ component: any WidgetComponent)
    /// The size the component's native widget chooses for a proposal (its intrinsic/greedy size).
    func measureComponent(_ handle: Handle, _ component: any WidgetComponent, _ proposal: ProposedViewSize) -> CGSize
    /// Notify a native-composite component that its children have been inserted/reconciled (so it can
    /// build itself from them — e.g. a TabView's tab bar). No-op for components without that need.
    func didInsertChildren(_ handle: Handle, _ component: any WidgetComponent)

    // MARK: - Tree, cross-cutting attachments, layout

    func insert(_ child: Handle, into parent: Handle, at index: Int)
    /// Move an already-inserted `child` to position `index` among `parent`'s children, preserving the
    /// widget (and its native state). Used by the reconciler to reorder keyed children without rebuilding.
    func move(_ child: Handle, in parent: Handle, to index: Int)
    func remove(_ child: Handle, from parent: Handle)
    /// Apply the cross-cutting node patch (accessibility set by a modifier on any widget). Widget content is
    /// configured by the component's renderer, not here.
    func configure(_ handle: Handle, _ patch: WidgetPatch)
    /// Install the scroll handler on a `.scroll` widget (nil for non-scroll widgets — a no-op). Cross-cutting.
    func setScrollHandler(_ handle: Handle, _ handler: (@MainActor (CGSize) -> Void)?)
    /// Install a tap-gesture recognizer on `handle` from `.onTapGesture` (nil removes it). Cross-cutting:
    /// can wrap any widget. The toolkit fires `spec.action` after `spec.count` taps.
    func setTapHandler(_ handle: Handle, _ spec: TapGestureSpec?)
    /// Install a long-press recognizer (`.onLongPressGesture`). Default: no-op.
    func setLongPressHandler(_ handle: Handle, _ spec: LongPressGestureSpec?)
    /// Install a pointer enter/leave (hover) tracker (`.onHover`). Default: no-op.
    func setHoverHandler(_ handle: Handle, _ handler: (@MainActor (Bool) -> Void)?)
    /// Install a drag recognizer (`.gesture(DragGesture())`). Default: no-op.
    func setDragHandler(_ handle: Handle, _ spec: DragGestureSpec?)
    /// Install a pinch/magnify recognizer (`.gesture(MagnifyGesture())`). Default: no-op.
    func setMagnifyHandler(_ handle: Handle, _ spec: MagnifyGestureSpec?)
    /// Install a rotation recognizer (`.gesture(RotateGesture())`). Default: no-op.
    func setRotateHandler(_ handle: Handle, _ spec: RotateGestureSpec?)
    /// Install a submit handler (`.onSubmit`) fired when the user presses Return in a text field. Default: no-op.
    func setSubmitHandler(_ handle: Handle, _ handler: (@MainActor () -> Void)?)
    /// Drive a `.fileImporter` presentation attached to `handle` (cross-cutting; can wrap any widget): when
    /// `spec.isPresented` transitions true, show the native open panel, then call `onCompletion` + reset.
    func configureFileImporter(_ handle: Handle, _ spec: FileImporterSpec)
    /// Drive a `.fileExporter` presentation: show the native save panel, write `spec.data`, then finish.
    func configureFileExporter(_ handle: Handle, _ spec: FileExporterSpec)

    // MARK: - Framework-owned layout

    /// Position `handle` at an absolute frame in its parent (container) widget's coordinate space (top-left
    /// origin). Containers are plain absolute-positioning views — HopUI's layout engine owns all geometry.
    func setFrame(_ handle: Handle, _ rect: CGRect)
    /// The size `handle` chooses for a proposal — its intrinsic/natural size (text metrics, control size).
    /// Shapes are greedy and return the proposal; a `nil` axis means "use the natural size".
    func measure(_ handle: Handle, _ proposal: ProposedViewSize) -> CGSize
    /// The widget's current actual size (used to lay out content inside a native composite's panes).
    func sizeOf(_ handle: Handle) -> CGSize
}

/// A toolkit that can also host a window and run the platform main loop.
@MainActor
public protocol AppToolkit: RenderToolkit {
    /// Create the application window titled `title`, then call `onReady` with the content
    /// container handle (into which the root view is mounted) and run the platform main loop.
    func run(title: String, onReady: @escaping @MainActor (Handle) -> Void)

    /// Open an additional, secondary window titled `title` while the main loop is already running,
    /// calling `onReady` with its content container handle. Used by `openWindow(id:)` to present the
    /// windows declared by `Window(_:id:)` scenes. The toolkit retains the window.
    func openWindow(title: String, onReady: @escaping @MainActor (Handle) -> Void)

    /// Install the window's top toolbar from the given items (text and buttons). Called on mount
    /// and whenever the toolbar content changes.
    func setToolbar(_ items: [ToolbarItemSpec])

    /// Install the app menu bar from the given top-level menus. Called on mount and whenever the
    /// menus change.
    func setMenu(_ menus: [MenuSpec])

    /// Run `work` on the platform main thread on a later loop iteration. Used to defer the re-render
    /// triggered by an `@Observable` mutation until after the current event finishes (so it reads
    /// committed values). Implemented via the toolkit's idle/timer mechanism.
    func scheduleOnMainThread(_ work: @escaping @MainActor () -> Void)

    /// Apply the preferred light/dark appearance to the app/window. `nil` follows the system. Each
    /// toolkit has its own switch (NSAppearance / GtkSettings / QStyleHints). Called on mount and
    /// whenever `.preferredColorScheme` changes.
    func setColorScheme(_ colorScheme: ColorScheme?)

    /// Whether this toolkit renders the navigation bar (the title from an enclosing `NavigationStack`) in
    /// native window chrome (e.g. a GtkHeaderBar) via ``setNavigationTitle(_:)``. When false (the
    /// default), `NavigationStack` renders a portable inline title instead — so toolkits that have not
    /// adopted native nav chrome keep working unchanged.
    var handlesNavigationBarNatively: Bool { get }

    /// Set the navigation title shown in the window's native header chrome (the resolved title from the
    /// enclosing `NavigationStack`); `nil` clears it. Only consulted when `handlesNavigationBarNatively`
    /// is true. Called on mount and whenever the resolved title changes.
    func setNavigationTitle(_ title: String?)

    /// The window's current content size (the layout engine's root proposal).
    func contentSize() -> CGSize
    /// Install a handler the toolkit calls whenever the window content size changes, so the runtime can
    /// re-run the layout pass. Called once on mount.
    func setRelayoutHandler(_ handler: @escaping @MainActor () -> Void)
}

/// Default no-ops for the newer gesture recognizers, so a backend only overrides the ones it wires (e.g.
/// trackpad magnify/rotate aren't installed on every toolkit). The cross-cutting reconciler calls all of
/// these on every node; an un-overridden one simply does nothing.
public extension RenderToolkit {
    func setLongPressHandler(_ handle: Handle, _ spec: LongPressGestureSpec?) {}
    func setHoverHandler(_ handle: Handle, _ handler: (@MainActor (Bool) -> Void)?) {}
    func setDragHandler(_ handle: Handle, _ spec: DragGestureSpec?) {}
    func setMagnifyHandler(_ handle: Handle, _ spec: MagnifyGestureSpec?) {}
    func setRotateHandler(_ handle: Handle, _ spec: RotateGestureSpec?) {}
    func setSubmitHandler(_ handle: Handle, _ handler: (@MainActor () -> Void)?) {}
}

/// Default navigation-chrome behavior: a toolkit renders the navigation bar inline (via `NavigationStack`)
/// and has no native nav chrome. A backend that has one (e.g. GTK's header bar) overrides both members.
public extension AppToolkit {
    var handlesNavigationBarNatively: Bool { false }
    func setNavigationTitle(_ title: String?) {}
}
