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

    // MARK: - Legacy per-kind path (being migrated onto the component system above)

    func makeWidget(_ kind: WidgetKind) -> Handle
    func configure(_ handle: Handle, _ patch: WidgetPatch)
    func insert(_ child: Handle, into parent: Handle, at index: Int)
    /// Move an already-inserted `child` to position `index` among `parent`'s children, preserving the
    /// widget (and its native state). Used by the reconciler to reorder keyed children without
    /// rebuilding them.
    func move(_ child: Handle, in parent: Handle, to index: Int)
    func remove(_ child: Handle, from parent: Handle)
    func setAction(_ handle: Handle, _ action: (@MainActor () -> Void)?)
    func setTextHandler(_ handle: Handle, _ handler: (@MainActor (String) -> Void)?)
    func setValueHandler(_ handle: Handle, _ handler: (@MainActor (Double) -> Void)?)
    /// Install the on/off-change handler for a `.toggle` widget (called with the new state). Called with
    /// `nil` for non-toggle widgets (a no-op).
    func setBoolHandler(_ handle: Handle, _ handler: (@MainActor (Bool) -> Void)?)
    /// Configure a lazily-virtualized list widget. Called once on creation and again whenever the
    /// row count or selection changes; the toolkit owns row recycling and on-demand row fetching.
    func configureList(_ handle: Handle, _ spec: ListSpec)
    /// Configure a custom-drawn shape widget. Called once on creation and again on every reconcile
    /// (the spec is not `Equatable`), so the toolkit stores the spec and triggers a redraw using its
    /// native 2D drawing API (CoreGraphics / Cairo / QPainter).
    func configureShape(_ handle: Handle, _ spec: ShapeSpec)
    /// Configure a drop-down action menu (``Menu``): set the button label and (re)build the popup of
    /// entries (buttons / separators / submenus) using the toolkit's native menu API.
    func configureMenu(_ handle: Handle, _ menu: MenuContent)
    /// Configure a selection drop-down (``Picker``): set the options and selected index, and wire the
    /// selection callback, using the toolkit's native popup/combo control.
    func configurePicker(_ handle: Handle, _ spec: PickerSpec)
    /// Configure a date/time chooser (``DatePicker``): set the value, optional bounds, edited components,
    /// and style, and wire the change callback, using the toolkit's native date control (NSDatePicker /
    /// GtkCalendar+spinners / QDateTimeEdit). Reapplied each reconcile (the spec is not `Equatable`).
    func configureDatePicker(_ handle: Handle, _ spec: DatePickerSpec)
    /// Configure a color chooser (``ColorPicker``): reflect the current color and opacity-editing flag, and
    /// wire the change callback, using the toolkit's native color control (NSColorWell / GtkColorButton /
    /// a QColorDialog swatch button). Reapplied each reconcile (the spec is not `Equatable`).
    func configureColorPicker(_ handle: Handle, _ spec: ColorPickerSpec)
    /// Drive a `.fileImporter` presentation attached to `handle`: when `spec.isPresented` transitions true,
    /// show the toolkit's native open panel (NSOpenPanel / GtkFileChooserNative / QFileDialog) parented to
    /// the handle's window; on finish call `spec.onCompletion` and `spec.setPresented(false)`. Reapplied
    /// each reconcile; the toolkit guards against re-presenting while already showing.
    func configureFileImporter(_ handle: Handle, _ spec: FileImporterSpec)
    /// Drive a `.fileExporter` presentation: show the native save panel, write `spec.data` to the chosen
    /// URL, then call `spec.onCompletion` and `spec.setPresented(false)`.
    func configureFileExporter(_ handle: Handle, _ spec: FileExporterSpec)
    /// Configure a hierarchical tree (``OutlineGroup`` / `List(_:children:)`): (re)build the native tree from
    /// `spec.roots`, reflect the selection, and wire the selection callback, using the toolkit's native tree
    /// widget (NSOutlineView / GtkTreeListModel / QTreeWidget).
    func configureOutline(_ handle: Handle, _ spec: OutlineSpec)
    /// Configure an image leaf (``Image``): resolve `spec.source` to a native image, apply
    /// resizable/content-mode/template-tint, and reflect accessibility, using the toolkit's native image
    /// widget (NSImageView / GtkPicture / QLabel+QPixmap). Reapplied each reconcile (not `Equatable`).
    func configureImage(_ handle: Handle, _ spec: ImageSpec)
    /// Configure a tabbed container (``TabView``): set the native tab widget's tab titles (from
    /// `spec.titles`, one per page child in order), reflect `spec.selectedIndex`, and wire `spec.onSelect`
    /// for user tab switches. Called *after* the page children are inserted (so the native tabs exist).
    func configureTabs(_ handle: Handle, _ spec: TabSpec)

    // MARK: - Framework-owned layout

    /// Position `handle` at an absolute frame in its parent (container) widget's coordinate space (top-left
    /// origin). Containers are plain absolute-positioning views — HopUI's layout engine owns all geometry.
    func setFrame(_ handle: Handle, _ rect: CGRect)
    /// The size `handle` chooses for a proposal — its intrinsic/natural size (text metrics, control size).
    /// Shapes are greedy and return the proposal; a `nil` axis means "use the natural size".
    func measure(_ handle: Handle, _ proposal: ProposedViewSize) -> CGSize
    /// The widget's current actual size (used to lay out content inside a native composite's panes).
    func sizeOf(_ handle: Handle) -> CGSize
    /// Install a scroll handler on a `.scroll` widget: the toolkit calls it with the current content
    /// offset whenever the user scrolls, so virtualized content can re-materialize its visible window.
    /// Called with `nil` for non-scroll widgets (a no-op).
    func setScrollHandler(_ handle: Handle, _ handler: (@MainActor (CGSize) -> Void)?)
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

    /// The window's current content size (the layout engine's root proposal).
    func contentSize() -> CGSize
    /// Install a handler the toolkit calls whenever the window content size changes, so the runtime can
    /// re-run the layout pass. Called once on mount.
    func setRelayoutHandler(_ handler: @escaping @MainActor () -> Void)
}
