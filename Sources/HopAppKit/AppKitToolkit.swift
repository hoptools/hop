// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(AppKit)
import AppKit
import HopUI
import UniformTypeIdentifiers  // map HopUI.UTType → the system UTType for file panels

/// A label that lets HopUI override its accessibility value and visibility. A plain `NSTextField`
/// exposes its string as the AX value and always stays an AX element, so `.accessibilityValue` and
/// `.accessibilityHidden` need these overrides to take effect.
public final class HopLabel: NSTextField {
    var axValueOverride: String?
    var axHidden = false
    public override func isAccessibilityElement() -> Bool { axHidden ? false : super.isAccessibilityElement() }
    public func accessibilityValue() -> Any? { axValueOverride ?? stringValue }
}

/// Opaque handle wrapping an `NSView` (and, for buttons, its action trampoline).
public final class AppKitWidget {
    let view: NSView
    var trampoline: ActionTrampoline?
    var textDelegate: TextFieldDelegate?
    var sliderTarget: SliderTarget?
    var switchTarget: SwitchTarget?
    var tabDelegate: TabViewDelegate?
    var listController: AppKitListController?
    var outlineController: AppKitOutlineController?
    // Retained action trampolines for a drop-down menu's items, and the selection target for a picker.
    var menuTrampolines: [ActionTrampoline] = []
    var pickerTarget: PickerTarget?
    var datePickerTarget: DatePickerTarget?
    var colorWellTarget: ColorWellTarget?
    // Guards against re-presenting a file panel while one is already showing (isPresented stays true).
    var importerPresenting = false
    var exporterPresenting = false
    // For a `.scroll` widget: the clip-view bounds-change observer driving the scroll handler.
    var scrollObserver: NSObjectProtocol?
    // For `.onTapGesture`: the installed click recognizer + its retained target.
    var tapRecognizer: NSClickGestureRecognizer?
    var tapTarget: TapTarget?
    // The newer gesture recognizers + their retained targets (one slot each, replaced on update).
    var longPressRecognizer: NSPressGestureRecognizer?
    var longPressTarget: PressTarget?
    var panRecognizer: NSPanGestureRecognizer?
    var panTarget: PanTarget?
    var magnifyRecognizer: NSMagnificationGestureRecognizer?
    var magnifyTarget: MagnifyTarget?
    var rotateRecognizer: NSRotationGestureRecognizer?
    var rotateTarget: RotateTarget?
    var hoverTrackingArea: NSTrackingArea?
    var hoverTarget: HoverTarget?
    // For a `.list` widget: the (low-priority) preferred-width constraint, so a sidebar list can be narrower.
    var listPreferredWidth: NSLayoutConstraint?
    init(_ view: NSView) { self.view = view }
}

/// Bridges an `NSPopUpButton`'s selection target/action to a stored Swift index callback (for `Picker`).
public final class PickerTarget: NSObject {
    var onSelect: (@MainActor (Int) -> Void)?
    @objc func changed(_ sender: NSPopUpButton) { onSelect?(sender.indexOfSelectedItem) }
    @objc func changedSegment(_ sender: NSSegmentedControl) { onSelect?(sender.selectedSegment) }
    @objc func changedRadio(_ sender: NSButton) { onSelect?(sender.tag) }
}

/// A plain top-left-origin container for the layout engine's absolute positioning (no auto-layout).
public final class FlippedView: NSView {
    public override var isFlipped: Bool { true }
}

/// A custom-drawn shape view. It is flipped (top-left origin) so its `CGContext` coordinate space
/// matches HopUI's / SwiftUI's, and it replays a ``ShapeSpec``'s path through CoreGraphics — the
/// idiomatic macOS way to draw arbitrary vector graphics.
public final class HopShapeView: NSView {
    var spec: ShapeSpec?
    public override var isFlipped: Bool { true }
    // A sensible default size when no `.frame` is applied (SwiftUI shapes are otherwise greedy, which
    // the MVP stack-based layout can't express); explicit frame constraints override this.
    public override var intrinsicContentSize: NSSize { NSSize(width: 100, height: 100) }

    public override func draw(_ dirtyRect: NSRect) {
        guard let spec, let ctx = NSGraphicsContext.current?.cgContext else { return }
        AppKitToolkit.drawShape(spec, in: bounds, context: ctx)
    }
}

/// An `NSImageView` for HopUI ``Image``s. NSImageView covers natural-size, stretch, and aspect-fit via
/// `imageScaling`; it has no built-in aspect-*fill*, so we draw that case ourselves (cover + clip). The
/// layout engine drives sizing; `isResizable` tells `measure` whether to report the natural or a greedy size.
public final class HopImageView: NSImageView {
    var isResizable = false
    var aspectFill = false

    public override func draw(_ dirtyRect: NSRect) {
        guard aspectFill, let image, image.size.width > 0, image.size.height > 0,
              let ctx = NSGraphicsContext.current?.cgContext else {
            super.draw(dirtyRect); return
        }
        ctx.saveGState()
        ctx.clip(to: bounds)
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let dw = image.size.width * scale, dh = image.size.height * scale
        image.draw(in: NSRect(x: bounds.midX - dw / 2, y: bounds.midY - dh / 2, width: dw, height: dh))
        ctx.restoreGState()
    }
}

/// Bridges Cocoa's target/action selector mechanism to a stored Swift closure.
public final class ActionTrampoline: NSObject {
    var action: (@MainActor () -> Void)?
    @objc func fire() { action?() }
}

/// Target for an `.onTapGesture` `NSClickGestureRecognizer`.
public final class TapTarget: NSObject {
    var action: (@MainActor () -> Void)?
    @objc func fire() { action?() }
}

/// Target for `.onLongPressGesture` — fires once when the press is recognized (`.began`).
public final class PressTarget: NSObject {
    var action: (@MainActor () -> Void)?
    @objc func fire(_ recognizer: NSPressGestureRecognizer) {
        if recognizer.state == .began { action?() }
    }
}

/// Target for a `DragGesture` `NSPanGestureRecognizer`. Reconstructs SwiftUI's `DragGesture.Value`
/// (start/current location + translation) and forwards changed/ended.
public final class PanTarget: NSObject {
    var onChanged: (@MainActor (DragGesture.Value) -> Void)?
    var onEnded: (@MainActor (DragGesture.Value) -> Void)?
    @objc func fire(_ recognizer: NSPanGestureRecognizer) {
        guard let view = recognizer.view else { return }
        let p = recognizer.location(in: view)
        let t = recognizer.translation(in: view)
        let translation = CGSize(width: t.x, height: t.y)
        let location = CGPoint(x: p.x, y: p.y)
        let start = CGPoint(x: p.x - t.x, y: p.y - t.y)
        let value = DragGesture.Value(startLocation: start, location: location, translation: translation)
        switch recognizer.state {
        case .changed: onChanged?(value)
        case .ended, .cancelled, .failed: onEnded?(value)
        default: break
        }
    }
}

/// Target for a `MagnifyGesture` `NSMagnificationGestureRecognizer`. AppKit's `magnification` is the delta
/// from 1.0, so the SwiftUI-style scale factor is `1 + magnification`.
public final class MagnifyTarget: NSObject {
    var onChanged: (@MainActor (MagnifyGesture.Value) -> Void)?
    var onEnded: (@MainActor (MagnifyGesture.Value) -> Void)?
    @objc func fire(_ recognizer: NSMagnificationGestureRecognizer) {
        let value = MagnifyGesture.Value(magnification: 1 + recognizer.magnification)
        switch recognizer.state {
        case .changed: onChanged?(value)
        case .ended, .cancelled, .failed: onEnded?(value)
        default: break
        }
    }
}

/// Target for a `RotateGesture` `NSRotationGestureRecognizer` (rotation in radians).
public final class RotateTarget: NSObject {
    var onChanged: (@MainActor (RotateGesture.Value) -> Void)?
    var onEnded: (@MainActor (RotateGesture.Value) -> Void)?
    @objc func fire(_ recognizer: NSRotationGestureRecognizer) {
        let value = RotateGesture.Value(rotation: Angle(radians: Double(recognizer.rotation)))
        switch recognizer.state {
        case .changed: onChanged?(value)
        case .ended, .cancelled, .failed: onEnded?(value)
        default: break
        }
    }
}

/// Owner of an `.onHover` `NSTrackingArea`; AppKit calls `mouseEntered`/`mouseExited` on the area's owner.
public final class HoverTarget: NSObject {
    var action: (@MainActor (Bool) -> Void)?
    // NSTrackingArea messages its owner with these selectors; the owner needn't be an NSResponder.
    @objc func mouseEntered(with event: NSEvent) { action?(true) }
    @objc func mouseExited(with event: NSEvent) { action?(false) }
}

/// Bridges `NSTextField`'s live-edit notifications to a stored Swift closure.
public final class TextFieldDelegate: NSObject, NSTextFieldDelegate {
    var onChange: (@MainActor (String) -> Void)?
    var onSubmit: (@MainActor () -> Void)?
    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        onChange?(field.stringValue)
    }
    // `.onSubmit` fires only on Return (not Tab or focus-loss), matching SwiftUI.
    public func controlTextDidEndEditing(_ notification: Notification) {
        guard let movement = notification.userInfo?["NSTextMovement"] as? Int,
              movement == NSTextMovement.return.rawValue else { return }
        onSubmit?()
    }
}

/// Bridges `NSSlider`'s continuous target/action to a stored Swift closure.
public final class SliderTarget: NSObject {
    var onChange: (@MainActor (Double) -> Void)?
    @objc func changed(_ sender: NSSlider) { onChange?(sender.doubleValue) }
}

/// Bridges `NSDatePicker`'s target/action to a stored Swift `Date` closure (for `DatePicker`).
/// Setting `dateValue` programmatically does not fire the action, so no feedback-loop guard is needed.
public final class DatePickerTarget: NSObject {
    var onChange: (@MainActor (Date) -> Void)?
    @objc func changed(_ sender: NSDatePicker) { onChange?(sender.dateValue) }
}

/// Bridges `NSColorWell`'s target/action to a stored Swift `Color` closure (for `ColorPicker`).
/// Programmatic `color` set does not fire the action, so no feedback-loop guard is needed.
public final class ColorWellTarget: NSObject {
    var onChange: (@MainActor (Color) -> Void)?
    @objc func changed(_ sender: NSColorWell) {
        let c = sender.color.usingColorSpace(.sRGB) ?? sender.color
        onChange?(Color(red: Double(c.redComponent), green: Double(c.greenComponent),
                        blue: Double(c.blueComponent), opacity: Double(c.alphaComponent)))
    }
}

/// Bridges `NSSwitch`'s target/action to a stored Swift bool closure (for `Toggle`).
public final class SwitchTarget: NSObject {
    var onChange: (@MainActor (Bool) -> Void)?
    @objc func changed(_ sender: NSSwitch) { onChange?(sender.state == .on) }
}

/// Bridges `NSTabView`'s selection delegate to a stored Swift index closure (for `TabView`). `suppress`
/// guards the callback while we reflect the bound selection programmatically.
public final class TabViewDelegate: NSObject, NSTabViewDelegate {
    var onSelect: (@MainActor (Int) -> Void)?
    var suppress = false
    public func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        guard !suppress, let item, let onSelect else { return }
        let index = tabView.indexOfTabViewItem(item)
        if index != NSNotFound { onSelect(index) }
    }
}

/// Data source + delegate for a lazily-virtualized `NSTableView`. NSTableView only ever creates row
/// views for visible rows and recycles them, so this scales to very large row counts.
public final class AppKitListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var count = 0
    var rowText: (@MainActor (Int) -> String)?
    var onSelect: (@MainActor (Int?) -> Void)?
    var suppressSelectionCallback = false
    weak var tableView: NSTableView?

    public func numberOfRows(in tableView: NSTableView) -> Int { count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("HopListCell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
        }
        field.stringValue = rowText?(row) ?? ""
        return field
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback, let tableView else { return }
        let row = tableView.selectedRow
        onSelect?(row >= 0 ? row : nil)
    }
}

/// Data source + delegate for an `NSOutlineView` driving a HopUI `.outline`/`.sidebarOutline` tree.
/// `OutlineSpec.Node` is a value type, so each node is wrapped in a reference-type `Item` (NSOutlineView
/// identifies rows by object identity). The item tree is rebuilt only when the structure signature
/// changes; selection is reflected separately by mapping the bound id through `itemsByKey`.
public final class AppKitOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Item {
        let node: OutlineSpec.Node
        let children: [Item]
        init(_ node: OutlineSpec.Node) {
            self.node = node
            self.children = node.children.map(Item.init)
        }
    }
    var rootItems: [Item] = []
    var itemsByKey: [String: Item] = [:]
    var signature: String?
    var onSelect: (@MainActor (AnyHashable?) -> Void)?
    var suppressSelectionCallback = false
    weak var outlineView: NSOutlineView?

    func setRoots(_ roots: [OutlineSpec.Node]) {
        rootItems = roots.map(Item.init)
        itemsByKey.removeAll()
        func index(_ items: [Item]) {
            for item in items { itemsByKey[item.node.key] = item; index(item.children) }
        }
        index(rootItems)
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? rootItems.count
    }
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Item)?.children[index] ?? rootItems[index]
    }
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }
    /// Non-selectable nodes are section headers: render them as source-list group rows (the idiomatic macOS
    /// sidebar header — no disclosure triangle, gray caption — mirroring SwiftUI's `List { Section { … } }`).
    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        !((item as? Item)?.node.selectable ?? true)
    }
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = (item as? Item)?.node
        let isHeader = !(node?.selectable ?? true)
        let identifier = NSUserInterfaceItemIdentifier(isHeader ? "HopOutlineHeader" : "HopOutlineCell")
        let field: NSTextField
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
        }
        // Section headers get the secondary-color caption look; rows use the standard label style.
        field.font = isHeader ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                              : .systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = isHeader ? .secondaryLabelColor : .labelColor
        field.stringValue = node?.title ?? ""
        return field
    }
    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Item)?.node.selectable ?? true
    }
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback, let outlineView else { return }
        let row = outlineView.selectedRow
        onSelect?(row >= 0 ? (outlineView.item(atRow: row) as? Item)?.node.id : nil)
    }
}

/// Vends prebuilt `NSToolbarItem`s by identifier for the window's `NSToolbar` (the idiomatic macOS
/// unified title-bar toolbar). Trampolines for button items are retained here.
public final class AppKitToolbarController: NSObject, NSToolbarDelegate {
    var itemsByID: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    var identifiers: [NSToolbarItem.Identifier] = []
    var trampolines: [ActionTrampoline] = []

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemsByID[itemIdentifier]
    }
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
}

/// AppKit (macOS) toolkit: maps HopUI widgets onto NSStackView / NSTextField / NSButton and lets
/// AppKit's stack views perform layout (the MVP defers the geometry-owning layout engine).
public final class AppKitToolkit: AppToolkit {
    public typealias Handle = AppKitWidget

    private var window: NSWindow?
    private let toolbarController = AppKitToolbarController()
    private var toolbarSignature: String?
    private var menuTrampolines: [ActionTrampoline] = []
    /// The most recent toolbar items + the resolved navigation title, so either can change independently
    /// and trigger a single combined rebuild of the unified toolbar (which has no public in-place mutation).
    private var lastToolbarItems: [ToolbarItemSpec] = []
    private var navigationTitleString: String?
    private let navigationTitleItemID = NSToolbarItem.Identifier("hop.navigation-title")
    private var menuSignature: String?
    // Secondary windows (e.g. About) are retained here so they aren't deallocated while open.
    private var secondaryWindows: [NSWindow] = []
    // Called by the runtime to re-run the layout engine when the window content size changes.
    private var relayoutHandler: (@MainActor () -> Void)?

    // MARK: - Open component system
    public static let toolkitID = ToolkitID.appKit
    /// Open registry of component renderers (built-ins registered below; third-party packages may add more).
    public let components = ComponentRegistry<AppKitWidget>()

    public init() { registerBuiltinComponents() }

    /// Create a component's native widget: registered renderer, else self-hosted `makeNative`, else a
    /// placeholder empty layer.
    public func realize(_ component: any WidgetComponent) -> AppKitWidget {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.make(component) }
        if let view = component.makeNative(Self.toolkitID) as? NSView { return AppKitWidget(view) }
        assertionFailure("HopUI/AppKit: no renderer registered for WidgetKey \"\(component.widgetKey.rawValue)\", and the component self-hosts no NSView")
        return AppKitWidget(FlippedView())
    }

    public func updateComponent(_ handle: AppKitWidget, _ component: any WidgetComponent) {
        if let renderer = components.renderer(for: component.widgetKey) { renderer.update(handle, component); return }
        component.updateNative(handle.view, Self.toolkitID)
    }

    public func measureComponent(_ handle: AppKitWidget, _ component: any WidgetComponent, _ proposal: ProposedViewSize) -> CGSize {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.measure(handle, component, proposal) }
        switch component.role {
        case .fill, .native: return proposal.resolved(.zero)
        default: return measure(handle, proposal)
        }
    }

    public func didInsertChildren(_ handle: AppKitWidget, _ component: any WidgetComponent) {
        components.renderer(for: component.widgetKey)?.afterChildren?(handle, component)
    }

    /// Register built-in component renderers. Populated as widgets migrate off the legacy `makeWidget` path.
    private func registerBuiltinComponents() {
        registerLeafComponents()
        registerSpecLeafComponents()
        registerContainerComponents()
        registerNativeCompositeComponents()
        registerImageComponent()
        registerPickerComponents()
    }

    /// Native composites (List, OutlineGroup, NavigationSplitView, TabView) — role `.native`; the widget
    /// arranges its own internals. TabView builds its tab bar from the children via `afterChildren`.
    private func registerNativeCompositeComponents() {
        for key: WidgetKey in [.list, .sidebarList] {
            components.register(.init(
                make: { [unowned self] c in let h = makeNativeWidget(key); if let s = (c as? ListComponent)?.spec { configureList(h, s) }; return h },
                update: { [unowned self] h, c in if let s = (c as? ListComponent)?.spec { configureList(h, s) } },
                measure: { [unowned self] h, _, p in measure(h, p) }
            ), for: key)
        }
        for key: WidgetKey in [.outline, .sidebarOutline] {
            components.register(.init(
                make: { [unowned self] c in let h = makeNativeWidget(key); if let s = (c as? OutlineComponent)?.spec { configureOutline(h, s) }; return h },
                update: { [unowned self] h, c in if let s = (c as? OutlineComponent)?.spec { configureOutline(h, s) } },
                measure: { [unowned self] h, _, p in measure(h, p) }
            ), for: key)
        }
        components.register(.init(
            make: { [unowned self] _ in makeNativeWidget(.splitView) },
            update: { _, _ in },
            measure: { [unowned self] h, _, p in measure(h, p) }
        ), for: .splitView)
        components.register(.init(
            make: { [unowned self] _ in makeNativeWidget(.tabView) },
            update: { _, _ in },
            measure: { [unowned self] h, _, p in measure(h, p) },
            afterChildren: { [unowned self] h, c in if let s = (c as? TabViewComponent)?.spec { configureTabs(h, s) } }
        ), for: .tabView)
    }

    /// Layout containers + layout-special layers (scroll/geometry/lazy/spacer) — empty native widgets the
    /// layout engine drives via the role + the node's layout callbacks.
    private func registerContainerComponents() {
        let containers: [WidgetKey] = [
            .vstack, .hstack, .zstack, .groupBox,
            .scroll, .geometry, .lazyStack, .spacer,
        ]
        for key in containers {
            components.register(.init(
                make: { [unowned self] _ in makeNativeWidget(key) },
                update: { _, _ in },
                measure: { [unowned self] h, _, p in measure(h, p) }
            ), for: key)
        }
    }

    /// Spec-carrying leaves (DatePicker, ColorPicker, Menu) — delegate to the existing configure path.
    private func registerSpecLeafComponents() {
        components.register(.init(
            make: { [unowned self] c in let h = makeNativeWidget(.datePicker); if let s = (c as? DatePickerComponent)?.spec { configureDatePicker(h, s) }; return h },
            update: { [unowned self] h, c in if let s = (c as? DatePickerComponent)?.spec { configureDatePicker(h, s) } },
            measure: { [unowned self] h, _, p in measure(h, p) }
        ), for: .datePicker)
        components.register(.init(
            make: { [unowned self] c in let h = makeNativeWidget(.colorPicker); if let s = (c as? ColorPickerComponent)?.spec { configureColorPicker(h, s) }; return h },
            update: { [unowned self] h, c in if let s = (c as? ColorPickerComponent)?.spec { configureColorPicker(h, s) } },
            measure: { [unowned self] h, _, p in measure(h, p) }
        ), for: .colorPicker)
        components.register(.init(
            make: { [unowned self] c in let h = makeNativeWidget(.menu); if let m = (c as? MenuComponent)?.content { configureMenu(h, m) }; return h },
            update: { [unowned self] h, c in if let m = (c as? MenuComponent)?.content { configureMenu(h, m) } },
            measure: { [unowned self] h, _, p in measure(h, p) }
        ), for: .menu)
        components.register(.init(
            make: { [unowned self] c in let h = makeNativeWidget(.shape); if let s = (c as? ShapeComponent)?.spec { configureShape(h, s) }; return h },
            update: { [unowned self] h, c in if let s = (c as? ShapeComponent)?.spec { configureShape(h, s) } },
            measure: { [unowned self] h, _, p in measure(h, p) }
        ), for: .shape)
    }

    /// Simple leaf widgets (Text/Button/TextField/SecureField/Slider/Toggle/Progress/Divider) — all
    /// "native widget + patch + handler". One renderer per key; `makeNativeWidget(key)` creates the widget.
    private func registerLeafComponents() {
        let leaves: [WidgetKey] = [
            .label, .button, .textField, .secureField,
            .slider, .toggle, .progress, .separator,
        ]
        for key in leaves {
            components.register(.init(
                make: { [unowned self] component in let handle = makeNativeWidget(key); applyLeaf(handle, component); return handle },
                update: { [unowned self] handle, component in applyLeaf(handle, component) },
                measure: { [unowned self] handle, _, proposal in measure(handle, proposal) }
            ), for: key)
        }
    }

    private func applyLeaf(_ handle: AppKitWidget, _ component: any WidgetComponent) {
        guard let leaf = component as? PrimitiveLeafComponent else { return }
        configure(handle, leaf.patch)
        setAction(handle, leaf.action)
        setTextHandler(handle, leaf.onChange)
        setValueHandler(handle, leaf.onChangeDouble)
        setBoolHandler(handle, leaf.onChangeBool)
    }

    /// `Picker` renderers — the style-variance pilot. Each style is a *different native widget*, registered
    /// under a distinct key ("picker.menu" / ".segmented" / ".radioGroup"); the reconciler recreates the
    /// widget when the key changes. Selection lives in `@State`, so it survives the recreate.
    private func registerPickerComponents() {
        // .menu / .automatic → NSPopUpButton (delegates to the existing picker path).
        let menu = ComponentRegistry<AppKitWidget>.Renderer(
            make: { [unowned self] component in
                let handle = makeNativeWidget(.picker)
                if let spec = (component as? PickerComponent)?.spec { configurePicker(handle, spec) }
                return handle
            },
            update: { [unowned self] handle, component in
                if let spec = (component as? PickerComponent)?.spec { configurePicker(handle, spec) }
            },
            measure: { [unowned self] handle, _, proposal in measure(handle, proposal) })
        components.register(menu, for: .picker(.menu))
        components.register(menu, for: .picker(.automatic))

        // .segmented → NSSegmentedControl (a genuinely different native widget).
        components.register(.init(
            make: { [unowned self] component in
                let seg = NSSegmentedControl()
                seg.segmentStyle = .texturedRounded
                seg.trackingMode = .selectOne
                let target = PickerTarget()
                seg.target = target
                seg.action = #selector(PickerTarget.changedSegment(_:))
                let handle = AppKitWidget(seg)
                handle.pickerTarget = target
                if let spec = (component as? PickerComponent)?.spec { applySegmented(seg, target, spec) }
                return handle
            },
            update: { [unowned self] handle, component in
                if let seg = handle.view as? NSSegmentedControl, let target = handle.pickerTarget,
                   let spec = (component as? PickerComponent)?.spec { applySegmented(seg, target, spec) }
            },
            measure: { [unowned self] handle, _, proposal in measure(handle, proposal) }
        ), for: .picker(.segmented))

        // .radioGroup → an NSStackView of radio buttons (a `.native` composite the renderer manages).
        components.register(.init(
            make: { [unowned self] component in
                let stack = NSStackView()
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 4
                let target = PickerTarget()
                let handle = AppKitWidget(stack)
                handle.pickerTarget = target
                if let spec = (component as? PickerComponent)?.spec { applyRadioGroup(stack, target, spec) }
                return handle
            },
            update: { [unowned self] handle, component in
                if let stack = handle.view as? NSStackView, let target = handle.pickerTarget,
                   let spec = (component as? PickerComponent)?.spec { applyRadioGroup(stack, target, spec) }
            },
            measure: { [unowned self] handle, _, proposal in measure(handle, proposal) }
        ), for: .picker(.radioGroup))
    }

    private func applySegmented(_ seg: NSSegmentedControl, _ target: PickerTarget, _ spec: PickerSpec) {
        target.onSelect = spec.onSelect
        if seg.segmentCount != spec.options.count { seg.segmentCount = spec.options.count }
        for (i, title) in spec.options.enumerated() { seg.setLabel(title, forSegment: i) }
        if let index = spec.selectedIndex, index >= 0, index < spec.options.count { seg.selectedSegment = index }
    }

    private func applyRadioGroup(_ stack: NSStackView, _ target: PickerTarget, _ spec: PickerSpec) {
        target.onSelect = spec.onSelect
        if stack.arrangedSubviews.count != spec.options.count {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            for (i, title) in spec.options.enumerated() {
                let radio = NSButton(radioButtonWithTitle: title, target: target,
                                     action: #selector(PickerTarget.changedRadio(_:)))
                radio.tag = i
                stack.addArrangedSubview(radio)
            }
        } else {
            for (i, view) in stack.arrangedSubviews.enumerated() { (view as? NSButton)?.title = spec.options[i] }
        }
        for (i, view) in stack.arrangedSubviews.enumerated() {
            (view as? NSButton)?.state = (i == spec.selectedIndex) ? .on : .off
        }
    }

    /// `Image` renderer — delegates to the existing image widget creation / configuration / measurement,
    /// so the migration onto the component path is behavior-preserving (the native code moves later).
    private func registerImageComponent() {
        components.register(.init(
            make: { [unowned self] component in
                let handle = makeNativeWidget(.image)
                if let spec = (component as? ImageComponent)?.spec { configureImage(handle, spec) }
                return handle
            },
            update: { [unowned self] handle, component in
                if let spec = (component as? ImageComponent)?.spec { configureImage(handle, spec) }
            },
            measure: { [unowned self] handle, _, proposal in measure(handle, proposal) }
        ), for: .image)
    }

    public func makeNativeWidget(_ key: WidgetKey) -> AppKitWidget {
        switch key {
        case .vstack, .hstack:
            // Containers are plain absolute-positioning layers; HopUI's layout engine owns geometry.
            return AppKitWidget(FlippedView())
        case .groupBox:
            // A card container: a flipped layer-backed view drawing a rounded, bordered, filled chrome.
            let card = FlippedView()
            card.wantsLayer = true
            card.layer?.cornerRadius = 8
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor.gray.withAlphaComponent(0.35).cgColor
            card.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.10).cgColor
            return AppKitWidget(card)
        case .label:
            let label = HopLabel(labelWithString: "")
            // Wrap like SwiftUI's Text: multi-line, word-wrapping. `measure` sets preferredMaxLayoutWidth to
            // the proposed width so the label reports the height needed at that width (not a single line).
            configureLabelWrapping(label)
            return AppKitWidget(label)
        case .textField:
            let field = NSTextField(string: "")
            field.isEditable = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            let widget = AppKitWidget(field)
            let delegate = TextFieldDelegate()
            field.delegate = delegate
            widget.textDelegate = delegate
            return widget
        case .secureField:
            let field = NSSecureTextField(string: "")
            field.isEditable = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            let widget = AppKitWidget(field)
            let delegate = TextFieldDelegate()
            field.delegate = delegate
            widget.textDelegate = delegate
            return widget
        case .toggle:
            let toggle = NSSwitch()
            let widget = AppKitWidget(toggle)
            let target = SwitchTarget()
            toggle.target = target
            toggle.action = #selector(SwitchTarget.changed(_:))
            widget.switchTarget = target
            return widget
        case .button:
            let button = NSButton(title: "", target: nil, action: nil)
            button.bezelStyle = .rounded
            let widget = AppKitWidget(button)
            let trampoline = ActionTrampoline()
            button.target = trampoline
            button.action = #selector(ActionTrampoline.fire)
            widget.trampoline = trampoline
            return widget
        case .slider:
            let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
            slider.isContinuous = true
            let widget = AppKitWidget(slider)
            let target = SliderTarget()
            slider.target = target
            slider.action = #selector(SliderTarget.changed(_:))
            widget.sliderTarget = target
            return widget
        case .list:
            return makeList(sidebar: false)
        case .sidebarList:
            return makeList(sidebar: true)
        case .outline:
            return makeOutline(sidebar: false)
        case .sidebarOutline:
            return makeOutline(sidebar: true)
        case .splitView:
            let split = NSSplitView()
            split.isVertical = true
            split.dividerStyle = .thin
            return AppKitWidget(split)
        case .tabView:
            let tab = NSTabView()
            let widget = AppKitWidget(tab)
            let delegate = TabViewDelegate()
            tab.delegate = delegate
            widget.tabDelegate = delegate
            return widget
        case .shape:
            return AppKitWidget(HopShapeView())
        case .image:
            let imageView = HopImageView()
            imageView.imageScaling = .scaleNone
            imageView.imageAlignment = .alignCenter
            return AppKitWidget(imageView)
        case .menu:
            // A pull-down button: item 0 is the always-shown label; the rest are the actions.
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            return AppKitWidget(popup)
        case .picker:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let widget = AppKitWidget(popup)
            let target = PickerTarget()
            popup.target = target
            popup.action = #selector(PickerTarget.changed(_:))
            widget.pickerTarget = target
            return widget
        case .datePicker:
            // Style/elements/value are set in configureDatePicker; this is just a sensible default.
            let picker = NSDatePicker()
            picker.datePickerMode = .single
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay]
            picker.isBezeled = true
            let widget = AppKitWidget(picker)
            let target = DatePickerTarget()
            picker.target = target
            picker.action = #selector(DatePickerTarget.changed(_:))
            widget.datePickerTarget = target
            return widget
        case .colorPicker:
            let well = NSColorWell()
            let widget = AppKitWidget(well)
            let target = ColorWellTarget()
            well.target = target
            well.action = #selector(ColorWellTarget.changed(_:))
            widget.colorWellTarget = target
            return widget
        case .separator:
            let box = NSBox()
            box.boxType = .separator
            return AppKitWidget(box)
        case .zstack, .geometry, .lazyStack, .spacer:
            // Absolute-positioning layers for the layout engine (no native auto-layout).
            return AppKitWidget(FlippedView())
        case .scroll:
            // A native scroll viewport; its single content child becomes the (flipped) document view.
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            return AppKitWidget(scroll)
        case .progress:
            let indicator = NSProgressIndicator()
            indicator.style = .bar
            indicator.isIndeterminate = false
            indicator.minValue = 0
            indicator.maxValue = 1
            return AppKitWidget(indicator)
        case .window:
            return AppKitWidget(NSView())
        default:
            // Only registered renderers call this, with keys this switch knows — an unknown key is a bug
            // (a missing registration / a typo). Trap in debug; degrade to a plain layer in release.
            assertionFailure("HopUI/AppKit: makeNativeWidget has no native widget for key \"\(key.rawValue)\"")
            return AppKitWidget(FlippedView())
        }
    }

    /// Create a virtualized list (NSTableView in an NSScrollView). When `sidebar`, the source-list style,
    /// vibrant material, borderless scroll, and narrower width are baked in at creation — so the table is
    /// never restyled while live (a style change reloads the table and clobbers the bound selection).
    private func makeList(sidebar: Bool) -> AppKitWidget {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HopListColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 20
        tableView.style = sidebar ? .sourceList : .plain
        tableView.selectionHighlightStyle = sidebar ? .sourceList : .regular
        let controller = AppKitListController()
        controller.tableView = tableView
        tableView.dataSource = controller
        tableView.delegate = controller

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = sidebar ? .noBorder : .bezelBorder
        scroll.drawsBackground = !sidebar  // a sidebar blends with the window (vibrant) rather than drawing its own bg
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Preferred width (overridable by dragging the divider), with a hard minimum; sidebars are narrower.
        let preferredWidth = scroll.widthAnchor.constraint(equalToConstant: sidebar ? 200 : 260)
        preferredWidth.priority = NSLayoutConstraint.Priority(500)
        preferredWidth.isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let widget = AppKitWidget(scroll)
        widget.listController = controller
        widget.listPreferredWidth = preferredWidth
        return widget
    }

    /// Create a hierarchical tree (NSOutlineView in an NSScrollView). When `sidebar`, the source-list
    /// style and borderless vibrant scroll are baked in at creation (mirroring `makeList(sidebar:)`), so
    /// the tree is never restyled while live (a style change reloads and clobbers the bound selection).
    private func makeOutline(sidebar: Bool) -> AppKitWidget {
        let outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HopOutlineColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = true
        outlineView.style = sidebar ? .sourceList : .plain
        outlineView.selectionHighlightStyle = sidebar ? .sourceList : .regular
        let controller = AppKitOutlineController()
        controller.outlineView = outlineView
        outlineView.dataSource = controller
        outlineView.delegate = controller

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.borderType = sidebar ? .noBorder : .bezelBorder
        scroll.drawsBackground = !sidebar  // a sidebar blends with the window (vibrant) rather than drawing its own bg
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = scroll.widthAnchor.constraint(equalToConstant: sidebar ? 200 : 260)
        preferredWidth.priority = NSLayoutConstraint.Priority(500)
        preferredWidth.isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let widget = AppKitWidget(scroll)
        widget.outlineController = controller
        widget.listPreferredWidth = preferredWidth
        return widget
    }

    /// Build an `NSMenu` from HopUI menu entries, collecting per-item action trampolines (which must be
    /// retained for the menu to work).
    private func buildMenu(_ entries: [MenuEntry], into menu: NSMenu, trampolines: inout [ActionTrampoline]) {
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .button(let title, let action):
                let item = NSMenuItem(title: title, action: #selector(ActionTrampoline.fire), keyEquivalent: "")
                let trampoline = ActionTrampoline()
                trampoline.action = action
                item.target = trampoline
                trampolines.append(trampoline)
                menu.addItem(item)
            case .submenu(let title, let subEntries):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                buildMenu(subEntries, into: submenu, trampolines: &trampolines)
                item.submenu = submenu
                menu.addItem(item)
            }
        }
    }

    public func configure(_ handle: AppKitWidget, _ patch: WidgetPatch) {
        if let text = patch.text, let label = handle.view as? NSTextField {
            label.stringValue = text
            // `.multilineTextAlignment` when set; otherwise HopUI's centered-label default.
            label.alignment = patch.textAlignment.map(Self.nsTextAlignment) ?? .center
        }
        if let title = patch.title, let button = handle.view as? NSButton {
            button.title = title
        }
        if let placeholder = patch.placeholder, let field = handle.view as? NSTextField {
            field.placeholderString = placeholder
        }
        if let value = patch.value, let field = handle.view as? NSTextField {
            // Guard against resetting the value (and the cursor) to what's already shown, which
            // also prevents a feedback loop when our own edit triggers a re-render.
            if field.stringValue != value { field.stringValue = value }
        }
        if let slider = handle.view as? NSSlider {
            if let minV = patch.minValue { slider.minValue = minV }
            if let maxV = patch.maxValue { slider.maxValue = maxV }
            if let v = patch.doubleValue, abs(slider.doubleValue - v) > 0.0001 {
                slider.doubleValue = v
            }
        }
        if let on = patch.boolValue, let toggle = handle.view as? NSSwitch {
            let target: NSControl.StateValue = on ? .on : .off
            if toggle.state != target { toggle.state = target }
        }

        // Styling: text color / font (labels), and background fill (any view).
        if let fg = patch.foregroundColor, let label = handle.view as? NSTextField {
            label.textColor = Self.nsColor(fg)
        }
        if (patch.font != nil || patch.fontWeight != nil || patch.italic != nil || patch.monospaced != nil),
           let label = handle.view as? NSTextField {
            label.font = Self.nsFont(patch.font, weight: patch.fontWeight,
                                     italic: patch.italic ?? false, monospaced: patch.monospaced ?? false,
                                     current: label.font)
            // Setting the font can re-enable single-line mode; re-assert wrapping for HopUI labels.
            if let hop = label as? HopLabel { configureLabelWrapping(hop) }
        }
        if let bg = patch.backgroundColor {
            if let label = handle.view as? NSTextField {
                label.drawsBackground = true
                label.backgroundColor = Self.nsColor(bg)
            } else {
                handle.view.wantsLayer = true
                handle.view.layer?.backgroundColor = Self.nsColor(bg).cgColor
            }
        }

        // Progress bar: a fraction is determinate; nil is indeterminate (animated).
        if let indicator = handle.view as? NSProgressIndicator {
            if let value = patch.progressValue {
                indicator.isIndeterminate = false
                indicator.stopAnimation(nil)
                indicator.doubleValue = value
            } else {
                indicator.isIndeterminate = true
                indicator.startAnimation(nil)
            }
        }

        // Accessibility → NSAccessibility (read by VoiceOver / Accessibility Inspector).
        let view = handle.view
        if let label = patch.accessibilityLabel { view.setAccessibilityLabel(label) }
        if let hint = patch.accessibilityHint { view.setAccessibilityHelp(hint) }
        if let identifier = patch.accessibilityIdentifier { view.setAccessibilityIdentifier(identifier) }
        if let value = patch.accessibilityValue {
            if let label = view as? HopLabel { label.axValueOverride = value } else { view.setAccessibilityValue(value) }
        }
        if let hidden = patch.accessibilityHidden {
            if let label = view as? HopLabel { label.axHidden = hidden } else { view.setAccessibilityElement(!hidden) }
        }
        if let traits = patch.accessibilityTraits {
            if traits.contains(.isButton) { view.setAccessibilityRole(.button) }
            else if traits.contains(.isImage) { view.setAccessibilityRole(.image) }
        }

        // `.opacity` — alphaValue composites the whole subtree. `.disabled` — NSControls toggle isEnabled;
        // a non-control container has no enabled state, so recurse to its descendant controls.
        view.alphaValue = CGFloat(patch.opacity ?? 1)
        if let enabled = patch.isEnabled { Self.applyEnabled(view, enabled) }
    }

    /// Apply `.disabled` on AppKit: an `NSControl` toggles its own `isEnabled`; any other view (a container)
    /// has no enabled state, so disable/enable its descendant controls.
    private static func applyEnabled(_ view: NSView, _ enabled: Bool) {
        if let control = view as? NSControl { control.isEnabled = enabled }
        else { for sub in view.subviews { applyEnabled(sub, enabled) } }
    }

    private static func nsColor(_ color: Color) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.opacity)
    }

    private static func nsTextAlignment(_ alignment: TextAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    /// Apply the `.italic` symbolic trait to a font via its descriptor, preserving size/weight/family.
    private static func italicized(_ font: NSFont, size: CGFloat) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(.italic)
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    private static func nsFont(_ font: Font?, weight: Font.Weight?, italic: Bool, monospaced: Bool,
                              current: NSFont?) -> NSFont {
        let size = font.map { CGFloat($0.size) } ?? (current?.pointSize ?? NSFont.systemFontSize)
        // Base face: a named family (its name selects weight on macOS), else monospaced system, else system.
        var base: NSFont
        if let family = font?.family, !monospaced, let named = NSFont(name: family, size: size) {
            base = named
        } else if monospaced {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: nsWeight(weight ?? font?.weight ?? .regular))
        } else {
            base = NSFont.systemFont(ofSize: size, weight: nsWeight(weight ?? font?.weight ?? .regular))
        }
        return italic ? italicized(base, size: size) : base
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    public func insert(_ child: AppKitWidget, into parent: AppKitWidget, at index: Int) {
        if let scroll = parent.view as? NSScrollView {
            // The scroll viewport's single content child is its document view (sized by the engine).
            child.view.translatesAutoresizingMaskIntoConstraints = true
            scroll.documentView = child.view
            return
        }
        if let split = parent.view as? NSSplitView {
            // Native split: the sidebar's preferred-width constraint sets the initial divider (and stays
            // draggable); the detail fills the rest. The engine lays out each pane's content (Phase 2).
            child.view.translatesAutoresizingMaskIntoConstraints = false
            split.addArrangedSubview(child.view)
            return
        }
        if let tab = parent.view as? NSTabView {
            // Native tabs: each child becomes a tab page; its view fills the content rect (sized by
            // NSTabView), and the engine lays the page's content out within that size. Titles set later.
            child.view.translatesAutoresizingMaskIntoConstraints = true
            child.view.autoresizingMask = [.width, .height]
            let item = NSTabViewItem(identifier: index)
            item.view = child.view
            tab.insertTabViewItem(item, at: Swift.min(index, tab.numberOfTabViewItems))
            return
        }
        // Absolute container: subviews are frame-positioned by the layout engine; subview order is z-order
        // (a later subview draws on top), which is what a ZStack's child order means.
        child.view.translatesAutoresizingMaskIntoConstraints = true
        addChildView(child.view, to: parent.view, at: index)
    }

    /// Insert `child` into `parent`'s subviews at z-index `index` (0 = bottom-most).
    private func addChildView(_ child: NSView, to parent: NSView, at index: Int) {
        let subviews = parent.subviews
        if index >= subviews.count {
            parent.addSubview(child)  // top-most
        } else {
            parent.addSubview(child, positioned: .below, relativeTo: subviews[index])
        }
    }

    public func move(_ child: AppKitWidget, in parent: AppKitWidget, to index: Int) {
        guard !(parent.view is NSSplitView), !(parent.view is NSTabView) else { return }  // panes/pages don't reorder in the MVP
        // Re-adding the same NSView preserves its native state (e.g. a text field's contents); only its
        // z-order changes.
        child.view.removeFromSuperview()
        addChildView(child.view, to: parent.view, at: index)
    }

    public func remove(_ child: AppKitWidget, from parent: AppKitWidget) {
        if let split = parent.view as? NSSplitView { split.removeArrangedSubview(child.view) }
        if let tab = parent.view as? NSTabView,
           let item = tab.tabViewItems.first(where: { $0.view === child.view }) {
            tab.removeTabViewItem(item)
        }
        child.view.removeFromSuperview()
    }

    public func setAction(_ handle: AppKitWidget, _ action: (@MainActor () -> Void)?) {
        handle.trampoline?.action = action
    }

    public func setTextHandler(_ handle: AppKitWidget, _ handler: (@MainActor (String) -> Void)?) {
        handle.textDelegate?.onChange = handler
    }

    public func setValueHandler(_ handle: AppKitWidget, _ handler: (@MainActor (Double) -> Void)?) {
        handle.sliderTarget?.onChange = handler
    }

    public func setBoolHandler(_ handle: AppKitWidget, _ handler: (@MainActor (Bool) -> Void)?) {
        handle.switchTarget?.onChange = handler
    }

    public func setSubmitHandler(_ handle: AppKitWidget, _ handler: (@MainActor () -> Void)?) {
        handle.textDelegate?.onSubmit = handler
    }

    // MARK: - Framework-owned layout

    public func setFrame(_ handle: AppKitWidget, _ rect: CGRect) {
        // Parents are flipped (top-left origin), so the engine's top-left rect maps directly.
        handle.view.frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        // NSTabView sizes the selected page's view lazily; force it now so the engine reads the page's
        // content rect (via sizeOf) in this same layout pass and centers the page content correctly.
        if handle.view is NSTabView { handle.view.layoutSubtreeIfNeeded() }
    }

    /// Configure a label to wrap like SwiftUI's Text. `usesSingleLineMode` must be false or it overrides
    /// `maximumNumberOfLines`/`lineBreakMode` and the text stays on one (truncated) line — which is what
    /// setting a font (`.fontWeight`) re-enables, so this is re-applied wherever the font changes + on measure.
    private func configureLabelWrapping(_ label: NSTextField) {
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        (label.cell as? NSTextFieldCell)?.truncatesLastVisibleLine = false
    }

    public func measure(_ handle: AppKitWidget, _ proposal: ProposedViewSize) -> CGSize {
        // Shapes are greedy: they fill whatever they're offered (default 100×100 when unspecified).
        if handle.view is HopShapeView { return proposal.resolved(CGSize(width: 100, height: 100)) }
        // Images: natural pixel size, unless `.resizable()` (then greedy, filling the offered frame).
        if let imageView = handle.view as? HopImageView {
            let natural = imageView.image?.size ?? CGSize(width: 24, height: 24)
            return imageView.isResizable ? proposal.resolved(natural) : natural
        }
        // A HopUI label (Text) wraps like SwiftUI's Text: report the height needed at the proposed width.
        // Re-assert the wrap config here (every layout pass) because setting `.font`/`.fontWeight` resets it;
        // preferredMaxLayoutWidth makes the wrapping label's intrinsic size account for line breaks (a nil
        // proposal → 0 → its ideal single-line width).
        if let label = handle.view as? HopLabel {
            configureLabelWrapping(label)
            // Size with the cell's OWN measurement so it matches what the label draws (font + text insets +
            // wrapping), which boundingRect under-reports — that mismatch left the last word wrapping to a
            // clipped 2nd line. A non-positive/absent proposal means "unspecified" → ideal single line.
            let constrained = (proposal.width.map { $0 > 0 } ?? false)
            let maxWidth: CGFloat = constrained ? proposal.width! : 100_000
            label.preferredMaxLayoutWidth = constrained ? maxWidth : 0
            let bounds = NSRect(x: 0, y: 0, width: maxWidth, height: .greatestFiniteMagnitude)
            let size = (label.cell as? NSTextFieldCell)?.cellSize(forBounds: bounds) ?? label.intrinsicContentSize
            return CGSize(width: ceil(size.width), height: ceil(size.height))
        }
        let fitting = handle.view.fittingSize
        // Flexible-width controls (text fields, sliders, progress bars) expand to the offered width.
        let flexibleWidth = (handle.view as? NSTextField)?.isEditable == true
            || handle.view is NSSlider || handle.view is NSProgressIndicator
        if flexibleWidth {
            let natural = Swift.max(fitting.width, 80)
            return CGSize(width: proposal.width.map { Swift.max($0, natural) } ?? natural, height: fitting.height)
        }
        return CGSize(width: fitting.width, height: fitting.height)
    }

    public func sizeOf(_ handle: AppKitWidget) -> CGSize {
        // A tab page's view lives inside the NSTabView (possibly nested in a private container); report the
        // tab's content area (below the tab bar) so the engine lays out — and centers — the page within it.
        var ancestor = handle.view.superview
        while let view = ancestor {
            if let tab = view as? NSTabView { return tab.contentRect.size }
            ancestor = view.superview
        }
        return CGSize(width: handle.view.frame.width, height: handle.view.frame.height)
    }

    public func setScrollHandler(_ handle: AppKitWidget, _ handler: (@MainActor (CGSize) -> Void)?) {
        guard let scroll = handle.view as? NSScrollView else { return }
        if let existing = handle.scrollObserver { NotificationCenter.default.removeObserver(existing); handle.scrollObserver = nil }
        guard let handler else { return }
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        handle.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { _ in
            MainActor.assumeIsolated {
                let origin = clip.bounds.origin
                handler(CGSize(width: origin.x, height: origin.y))
            }
        }
    }

    public func setTapHandler(_ handle: AppKitWidget, _ spec: TapGestureSpec?) {
        if let existing = handle.tapRecognizer {
            handle.view.removeGestureRecognizer(existing)
            handle.tapRecognizer = nil; handle.tapTarget = nil
        }
        guard let spec else { return }
        let target = TapTarget()
        target.action = spec.action
        let recognizer = NSClickGestureRecognizer(target: target, action: #selector(TapTarget.fire))
        recognizer.numberOfClicksRequired = Swift.max(1, spec.count)
        handle.view.addGestureRecognizer(recognizer)
        handle.tapRecognizer = recognizer
        handle.tapTarget = target
    }

    public func setLongPressHandler(_ handle: AppKitWidget, _ spec: LongPressGestureSpec?) {
        if let existing = handle.longPressRecognizer {
            handle.view.removeGestureRecognizer(existing)
            handle.longPressRecognizer = nil; handle.longPressTarget = nil
        }
        guard let spec else { return }
        let target = PressTarget()
        target.action = spec.action
        let recognizer = NSPressGestureRecognizer(target: target, action: #selector(PressTarget.fire(_:)))
        recognizer.minimumPressDuration = spec.minimumDuration
        handle.view.addGestureRecognizer(recognizer)
        handle.longPressRecognizer = recognizer
        handle.longPressTarget = target
    }

    public func setHoverHandler(_ handle: AppKitWidget, _ handler: (@MainActor (Bool) -> Void)?) {
        if let existing = handle.hoverTrackingArea {
            handle.view.removeTrackingArea(existing)
            handle.hoverTrackingArea = nil; handle.hoverTarget = nil
        }
        guard let handler else { return }
        let target = HoverTarget()
        target.action = handler
        // .inVisibleRect → the area auto-tracks the view's visible bounds (no manual resize bookkeeping).
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: target, userInfo: nil)
        handle.view.addTrackingArea(area)
        handle.hoverTrackingArea = area
        handle.hoverTarget = target
    }

    // Idempotent: the reconciler re-applies gesture handlers on every render, so the recognizer is created
    // ONCE and kept alive — only the target's closures are refreshed. Removing + re-adding the recognizer
    // each render would cancel an in-flight gesture (the new recognizer never saw the mouse-down), so a
    // continuous drag/magnify/rotate would die after its first event. Create/destroy only on nil↔non-nil.
    public func setDragHandler(_ handle: AppKitWidget, _ spec: DragGestureSpec?) {
        guard let spec else {
            if let existing = handle.panRecognizer { handle.view.removeGestureRecognizer(existing); handle.panRecognizer = nil; handle.panTarget = nil }
            return
        }
        if let target = handle.panTarget { target.onChanged = spec.onChanged; target.onEnded = spec.onEnded; return }
        let target = PanTarget()
        target.onChanged = spec.onChanged
        target.onEnded = spec.onEnded
        let recognizer = NSPanGestureRecognizer(target: target, action: #selector(PanTarget.fire(_:)))
        handle.view.addGestureRecognizer(recognizer)
        handle.panRecognizer = recognizer
        handle.panTarget = target
    }

    public func setMagnifyHandler(_ handle: AppKitWidget, _ spec: MagnifyGestureSpec?) {
        guard let spec else {
            if let existing = handle.magnifyRecognizer { handle.view.removeGestureRecognizer(existing); handle.magnifyRecognizer = nil; handle.magnifyTarget = nil }
            return
        }
        if let target = handle.magnifyTarget { target.onChanged = spec.onChanged; target.onEnded = spec.onEnded; return }
        let target = MagnifyTarget()
        target.onChanged = spec.onChanged
        target.onEnded = spec.onEnded
        let recognizer = NSMagnificationGestureRecognizer(target: target, action: #selector(MagnifyTarget.fire(_:)))
        handle.view.addGestureRecognizer(recognizer)
        handle.magnifyRecognizer = recognizer
        handle.magnifyTarget = target
    }

    public func setRotateHandler(_ handle: AppKitWidget, _ spec: RotateGestureSpec?) {
        guard let spec else {
            if let existing = handle.rotateRecognizer { handle.view.removeGestureRecognizer(existing); handle.rotateRecognizer = nil; handle.rotateTarget = nil }
            return
        }
        if let target = handle.rotateTarget { target.onChanged = spec.onChanged; target.onEnded = spec.onEnded; return }
        let target = RotateTarget()
        target.onChanged = spec.onChanged
        target.onEnded = spec.onEnded
        let recognizer = NSRotationGestureRecognizer(target: target, action: #selector(RotateTarget.fire(_:)))
        handle.view.addGestureRecognizer(recognizer)
        handle.rotateRecognizer = recognizer
        handle.rotateTarget = target
    }

    public func contentSize() -> CGSize {
        guard let content = window?.contentView else { return CGSize(width: 820, height: 760) }
        return CGSize(width: content.bounds.width, height: content.bounds.height)
    }

    public func setRelayoutHandler(_ handler: @escaping @MainActor () -> Void) {
        relayoutHandler = handler
        guard let window else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    public func configureList(_ handle: AppKitWidget, _ spec: ListSpec) {
        guard let controller = handle.listController, let tableView = controller.tableView else { return }
        controller.rowText = spec.rowText
        controller.onSelect = spec.onSelect
        if controller.count != spec.count {
            controller.count = spec.count
            tableView.reloadData()
        }
        let target = spec.selectedIndex
        if tableView.selectedRow != (target ?? -1) {
            controller.suppressSelectionCallback = true
            if let target {
                tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                tableView.scrollRowToVisible(target)
            } else {
                tableView.deselectAll(nil)
            }
            controller.suppressSelectionCallback = false
        }
    }

    public func configureShape(_ handle: AppKitWidget, _ spec: ShapeSpec) {
        guard let shapeView = handle.view as? HopShapeView else { return }
        shapeView.spec = spec
        shapeView.needsDisplay = true
    }

    public func configureImage(_ handle: AppKitWidget, _ spec: ImageSpec) {
        guard let imageView = handle.view as? HopImageView else { return }
        // Resolve the source to an NSImage.
        let image: NSImage?
        switch spec.source {
        case .system(let name):
            image = NSImage(systemSymbolName: name, accessibilityDescription: spec.label)
        case .named, .file:
            image = spec.resolvedURL().flatMap { NSImage(contentsOf: $0) }
        case .data(let data):
            image = NSImage(data: data)
        }
        imageView.image = image
        image?.isTemplate = spec.isTemplate
        imageView.contentTintColor = (spec.isTemplate ? spec.tint.map(Self.nsColor) : nil)

        // Scaling: natural when not resizable; otherwise stretch / aspect-fit / aspect-fill.
        imageView.isResizable = spec.resizable
        if !spec.resizable {
            imageView.aspectFill = false
            imageView.imageScaling = .scaleNone
        } else {
            switch spec.contentMode {
            case .none: imageView.aspectFill = false; imageView.imageScaling = .scaleAxesIndependently
            case .fit:  imageView.aspectFill = false; imageView.imageScaling = .scaleProportionallyUpOrDown
            case .fill: imageView.aspectFill = true;  imageView.imageScaling = .scaleNone  // drawn by HopImageView
            }
        }
        imageView.needsDisplay = true

        // Accessibility.
        imageView.setAccessibilityElement(!spec.isDecorative)
        if !spec.isDecorative { imageView.setAccessibilityLabel(spec.label) }
    }

    public func configureTabs(_ handle: AppKitWidget, _ spec: TabSpec) {
        guard let tab = handle.view as? NSTabView else { return }
        handle.tabDelegate?.onSelect = spec.onSelect
        for (index, title) in spec.titles.enumerated() where index < tab.numberOfTabViewItems {
            tab.tabViewItem(at: index).label = title
        }
        // Reflect the bound selection, suppressing the delegate so we don't re-report our own change.
        let target = Swift.max(0, Swift.min(spec.selectedIndex, tab.numberOfTabViewItems - 1))
        if tab.numberOfTabViewItems > 0, tab.indexOfTabViewItem(tab.selectedTabViewItem ?? tab.tabViewItem(at: 0)) != target {
            handle.tabDelegate?.suppress = true
            tab.selectTabViewItem(at: target)
            handle.tabDelegate?.suppress = false
        }
    }

    public func configureMenu(_ handle: AppKitWidget, _ menu: MenuContent) {
        guard let popup = handle.view as? NSPopUpButton else { return }
        let nsMenu = NSMenu()
        // Item 0 of a pull-down button is the always-shown label.
        nsMenu.addItem(NSMenuItem(title: menu.label, action: nil, keyEquivalent: ""))
        var trampolines: [ActionTrampoline] = []
        buildMenu(menu.entries, into: nsMenu, trampolines: &trampolines)
        handle.menuTrampolines = trampolines
        popup.menu = nsMenu
        popup.selectItem(at: 0)
    }

    public func configurePicker(_ handle: AppKitWidget, _ spec: PickerSpec) {
        guard let popup = handle.view as? NSPopUpButton else { return }
        handle.pickerTarget?.onSelect = spec.onSelect
        // Rebuild the item list only when it changes, so we don't disturb an in-progress selection.
        if popup.itemTitles != spec.options {
            popup.removeAllItems()
            popup.addItems(withTitles: spec.options)
        }
        if let index = spec.selectedIndex, index >= 0, index < popup.numberOfItems,
           popup.indexOfSelectedItem != index {
            popup.selectItem(at: index)
        }
    }

    public func configureDatePicker(_ handle: AppKitWidget, _ spec: DatePickerSpec) {
        guard let picker = handle.view as? NSDatePicker else { return }
        handle.datePickerTarget?.onChange = spec.onChange
        // Edited components → which fields are shown/editable.
        var elements: NSDatePicker.ElementFlags = []
        if spec.components.contains(.date) { elements.insert(.yearMonthDay) }
        if spec.components.contains(.hourAndMinute) { elements.insert(.hourMinute) }
        if elements.isEmpty { elements = [.yearMonthDay] }
        if picker.datePickerElements != elements { picker.datePickerElements = elements }
        // Style: graphical → an inline clock/calendar; everything else → a compact field + stepper.
        let style: NSDatePicker.Style = (spec.style == .graphical) ? .clockAndCalendar : .textFieldAndStepper
        if picker.datePickerStyle != style { picker.datePickerStyle = style }
        // Bounds first, then value (programmatic `dateValue` set does not fire the action → no loop).
        picker.minDate = spec.minDate
        picker.maxDate = spec.maxDate
        if picker.dateValue != spec.date { picker.dateValue = spec.date }
    }

    public func configureColorPicker(_ handle: AppKitWidget, _ spec: ColorPickerSpec) {
        guard let well = handle.view as? NSColorWell else { return }
        handle.colorWellTarget?.onChange = spec.onChange
        // Opacity editing is a property of the shared color panel the well opens.
        NSColorPanel.shared.showsAlpha = spec.supportsOpacity
        let target = Self.nsColor(spec.color)
        if well.color != target { well.color = target }   // programmatic set doesn't fire the action
    }

    private func appKitTypes(_ types: [HopUI.UTType]) -> [UniformTypeIdentifiers.UTType] {
        types.compactMap { t in
            if !t.identifier.isEmpty, let u = UniformTypeIdentifiers.UTType(t.identifier) { return u }
            if let ext = t.preferredFilenameExtension, let u = UniformTypeIdentifiers.UTType(filenameExtension: ext) { return u }
            return nil
        }
    }

    public func configureFileImporter(_ handle: AppKitWidget, _ spec: FileImporterSpec) {
        guard spec.isPresented else { handle.importerPresenting = false; return }
        guard !handle.importerPresenting else { return }
        handle.importerPresenting = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = spec.allowsMultipleSelection
        let types = appKitTypes(spec.allowedContentTypes)
        if !types.isEmpty { panel.allowedContentTypes = types }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            handle.importerPresenting = false
            spec.setPresented(false)
            if response == .OK { spec.onCompletion(.success(panel.urls)) }   // cancel: no completion (like SwiftUI)
        }
        if let window = handle.view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    public func configureFileExporter(_ handle: AppKitWidget, _ spec: FileExporterSpec) {
        guard spec.isPresented else { handle.exporterPresenting = false; return }
        guard !handle.exporterPresenting else { return }
        handle.exporterPresenting = true
        let panel = NSSavePanel()
        panel.nameFieldStringValue = spec.defaultFilename
        if let u = appKitTypes([spec.contentType]).first { panel.allowedContentTypes = [u] }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            handle.exporterPresenting = false
            spec.setPresented(false)
            if response == .OK, let url = panel.url {
                do { try spec.data.write(to: url); spec.onCompletion(.success(url)) }
                catch { spec.onCompletion(.failure(error)) }
            }
        }
        if let window = handle.view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    public func configureOutline(_ handle: AppKitWidget, _ spec: OutlineSpec) {
        guard let controller = handle.outlineController, let outlineView = controller.outlineView else { return }
        controller.onSelect = spec.onSelect
        // Rebuild the native item tree only when the structure changes (not on every reconcile, which
        // would collapse expansion and disturb an in-progress selection).
        let signature = spec.structureSignature
        if controller.signature != signature {
            controller.signature = signature
            controller.setRoots(spec.roots)
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)  // start fully expanded so the whole tree is visible
        }
        // Reflect the bound selection.
        let targetItem = spec.selectedID.flatMap { controller.itemsByKey["\($0.base)"] }
        let targetRow = targetItem.map { outlineView.row(forItem: $0) } ?? -1
        if outlineView.selectedRow != targetRow {
            controller.suppressSelectionCallback = true
            if targetRow >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
                outlineView.scrollRowToVisible(targetRow)
            } else {
                outlineView.deselectAll(nil)
            }
            controller.suppressSelectionCallback = false
        }
    }

    /// Build a `CGPath` from a HopUI ``Path`` by replaying each element through CoreGraphics' native
    /// path primitives (so rects/rounded-rects/ellipses/arcs stay exact, not Bézier approximations).
    static func cgPath(from path: Path) -> CGPath {
        let cg = CGMutablePath()
        for element in path.elements {
            switch element {
            case .move(let p): cg.move(to: p)
            case .line(let p): cg.addLine(to: p)
            case .quadCurve(let p, let c): cg.addQuadCurve(to: p, control: c)
            case .curve(let p, let c1, let c2): cg.addCurve(to: p, control1: c1, control2: c2)
            case .closeSubpath: cg.closeSubpath()
            case .rect(let r): cg.addRect(r)
            case .roundedRect(let r, let cs): cg.addRoundedRect(in: r, cornerWidth: cs.width, cornerHeight: cs.height)
            case .ellipse(let r): cg.addEllipse(in: r)
            case .arc(let center, let radius, let start, let end, let clockwise):
                // Our shape view is flipped (y-down), so SwiftUI's y-down `clockwise` maps to the
                // opposite winding in CoreGraphics' nominally y-up arc generation.
                cg.addArc(center: center, radius: radius,
                          startAngle: CGFloat(start.radians), endAngle: CGFloat(end.radians),
                          clockwise: !clockwise)
            }
        }
        return cg
    }

    /// Render a ``ShapeSpec`` into `rect` using CoreGraphics: build the path, apply the
    /// center-anchored offset/rotation/scale transform, then fill and/or stroke.
    static func drawShape(_ spec: ShapeSpec, in rect: CGRect, context ctx: CGContext) {
        let cgPath = cgPath(from: spec.path(rect))
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Transforms anchor on the shape's center: translate to center (+offset), rotate, scale, back.
        let cx = rect.midX, cy = rect.midY
        ctx.translateBy(x: cx + spec.offset.width, y: cy + spec.offset.height)
        if spec.rotation.radians != 0 { ctx.rotate(by: CGFloat(spec.rotation.radians)) }
        if spec.scaleX != 1 || spec.scaleY != 1 { ctx.scaleBy(x: spec.scaleX, y: spec.scaleY) }
        ctx.translateBy(x: -cx, y: -cy)

        if let gradient = spec.gradient {
            drawGradient(gradient, path: cgPath, rect: rect, context: ctx)
        } else if let fill = spec.fill {
            ctx.setFillColor(nsColor(fill).cgColor)
            ctx.addPath(cgPath)
            ctx.fillPath()
        }
        if let stroke = spec.stroke {
            ctx.setStrokeColor(nsColor(stroke).cgColor)
            ctx.setLineWidth(CGFloat(spec.lineWidth))
            ctx.addPath(cgPath)
            ctx.strokePath()
        }
    }

    /// Paint a gradient fill clipped to `cgPath`. Linear/radial use CoreGraphics' native drawing; angular
    /// (which CoreGraphics has no primitive for) is rendered as a fan of interpolated wedges.
    static func drawGradient(_ spec: GradientSpec, path cgPath: CGPath, rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.addPath(cgPath)
        ctx.clip()
        switch spec.kind {
        case .linear(let start, let end):
            guard let g = cgGradient(spec.stops) else { return }
            ctx.drawLinearGradient(g, start: start.point(in: rect), end: end.point(in: rect),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial(let center, let r0, let r1):
            guard let g = cgGradient(spec.stops) else { return }
            let c = center.point(in: rect)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: r0, endCenter: c, endRadius: r1,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .angular(let center, let startAngle, let endAngle):
            let c = center.point(in: rect)
            let radius = hypot(rect.width, rect.height)   // cover the whole clipped region
            let total = endAngle.radians - startAngle.radians
            let segments = 360
            for i in 0..<segments {
                let f0 = Double(i) / Double(segments), f1 = Double(i + 1) / Double(segments)
                ctx.setFillColor(nsColor(spec.color(at: CGFloat((f0 + f1) / 2))).cgColor)
                ctx.beginPath()
                ctx.move(to: c)
                ctx.addArc(center: c, radius: radius,
                           startAngle: CGFloat(startAngle.radians + total * f0),
                           endAngle: CGFloat(startAngle.radians + total * f1), clockwise: false)
                ctx.closePath()
                ctx.fillPath()
            }
        }
    }

    /// Build a `CGGradient` from HopUI gradient stops (device RGB).
    static func cgGradient(_ stops: [Gradient.Stop]) -> CGGradient? {
        guard !stops.isEmpty else { return nil }
        let colors = stops.map { nsColor($0.color).cgColor } as CFArray
        let locations = stops.map { CGFloat($0.location) }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations)
    }

    public func run(title: String, onReady: @escaping @MainActor (AppKitWidget) -> Void) {
        installAppKitMainExecutor()  // route hopTask onto the main run loop
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // Honor HOP_WINDOW_SIZE (uniform screenshot size) for the primary window; default 820×760.
        let requested = hopRequestedWindowSize()
        let winW = CGFloat(requested?.width ?? 820), winH = CGFloat(requested?.height ?? 760)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // A flipped content view so the layout engine's top-left origin maps directly to AppKit frames.
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        window.contentView = container
        self.window = window

        onReady(AppKitWidget(container))

        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    public func openWindow(title: String, onReady: @escaping @MainActor (AppKitWidget) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // We retain the window ourselves, so don't let Cocoa release it on close (avoids a crash).
        window.isReleasedWhenClosed = false
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        window.contentView = container

        onReady(AppKitWidget(container))

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        secondaryWindows.append(window)
    }

    public func setToolbar(_ items: [ToolbarItemSpec]) {
        lastToolbarItems = items
        rebuildToolbarChrome()
    }

    /// AppKit renders the navigation title in the window's unified toolbar (a centered item), not the OS
    /// window-title string — the idiomatic macOS in-window header.
    public var handlesNavigationBarNatively: Bool { true }

    public func setNavigationTitle(_ title: String?) {
        navigationTitleString = (title?.isEmpty == false) ? title : nil
        rebuildToolbarChrome()
    }

    /// Build the window's NSToolbar from the current toolbar items plus, when set, a centered navigation
    /// title item flanked by flexible spaces. NSToolbar has no public in-place item mutation, so it is
    /// rebuilt wholesale; a combined (items + title) signature guards against rebuilding on every flush.
    /// The OS `window.title` (set once in `run()`) is never changed; when a nav title is shown the window's
    /// own titlebar text is hidden so it is not duplicated.
    private func rebuildToolbarChrome() {
        guard let window else { return }
        let signature = toolbarSignature(lastToolbarItems) + "|title:" + (navigationTitleString ?? "")
        guard signature != self.toolbarSignature else { return }
        self.toolbarSignature = signature

        toolbarController.itemsByID = [:]
        toolbarController.identifiers = []
        toolbarController.trampolines = []
        for (index, spec) in lastToolbarItems.enumerated() {
            let id = NSToolbarItem.Identifier("hop.\(index)")
            let item = NSToolbarItem(itemIdentifier: id)
            switch spec.kind {
            case .text(let string):
                item.view = NSTextField(labelWithString: string)
            case .button(let title, let action):
                let button = NSButton(title: title, target: nil, action: nil)
                button.bezelStyle = .texturedRounded
                let trampoline = ActionTrampoline()
                trampoline.action = action
                button.target = trampoline
                button.action = #selector(ActionTrampoline.fire)
                toolbarController.trampolines.append(trampoline)
                item.view = button
            }
            toolbarController.itemsByID[id] = item
            toolbarController.identifiers.append(id)
        }
        if let title = navigationTitleString {
            let item = NSToolbarItem(itemIdentifier: navigationTitleItemID)
            let label = NSTextField(labelWithString: title)
            label.alignment = .center
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = title
            item.view = label
            item.minSize = NSSize(width: 80, height: 22)
            item.maxSize = NSSize(width: 400, height: 22)
            toolbarController.itemsByID[navigationTitleItemID] = item
            // Equal flexible spaces on both sides center the fixed-width title in the toolbar.
            toolbarController.identifiers.append(.flexibleSpace)
            toolbarController.identifiers.append(navigationTitleItemID)
            toolbarController.identifiers.append(.flexibleSpace)
        }
        window.titleVisibility = (navigationTitleString != nil) ? .hidden : .visible

        let toolbar = NSToolbar(identifier: "HopToolbar")
        toolbar.delegate = toolbarController
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        if #available(macOS 11.0, *) { window.toolbarStyle = .unified }
    }

    public func scheduleOnMainThread(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    public func setColorScheme(_ colorScheme: ColorScheme?) {
        let appearance: NSAppearance?
        switch colorScheme {
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .light: appearance = NSAppearance(named: .aqua)
        case nil: appearance = nil  // follow the system
        }
        NSApp.appearance = appearance
        window?.appearance = appearance
    }

    public func setMenu(_ menus: [MenuSpec]) {
        let signature = menus.map { menu in
            menu.title + "{" + menu.items.map { item in
                switch item.kind {
                case .button(let title, _): return "b:\(title)"
                case .command(let title, let command): return "c:\(title):\(command)"
                case .separator: return "-"
                }
            }.joined(separator: ",") + "}"
        }.joined(separator: "|")
        guard signature != menuSignature else { return }
        menuSignature = signature
        menuTrampolines = []

        let mainMenu = NSMenu()

        // The macOS app menu (bold app name) goes first and provides Quit.
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for spec in menus {
            let menuItem = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: spec.title)
            menuItem.submenu = submenu
            for item in spec.items {
                switch item.kind {
                case .separator:
                    submenu.addItem(.separator())
                case .button(let title, let action):
                    let mi = NSMenuItem(title: title, action: #selector(ActionTrampoline.fire), keyEquivalent: "")
                    let trampoline = ActionTrampoline()
                    trampoline.action = action
                    mi.target = trampoline
                    menuTrampolines.append(trampoline)
                    submenu.addItem(mi)
                case .command(let title, let command):
                    let (selector, key) = Self.selectorAndKey(command)
                    // target nil → routed to the first responder (the focused text field), which
                    // implements the standard cut:/copy:/paste: actions. This is the macOS idiom.
                    let mi = NSMenuItem(title: title, action: selector, keyEquivalent: key)
                    mi.target = nil
                    submenu.addItem(mi)
                }
            }
            mainMenu.addItem(menuItem)
        }

        NSApplication.shared.mainMenu = mainMenu
    }

    private static func selectorAndKey(_ command: StandardCommand) -> (Selector, String) {
        switch command {
        case .cut: return (Selector(("cut:")), "x")
        case .copy: return (Selector(("copy:")), "c")
        case .paste: return (Selector(("paste:")), "v")
        case .undo: return (Selector(("undo:")), "z")
        case .redo: return (Selector(("redo:")), "Z")
        case .selectAll: return (Selector(("selectAll:")), "a")
        }
    }

    private func toolbarSignature(_ items: [ToolbarItemSpec]) -> String {
        items.map { item in
            switch item.kind {
            case .text(let string): return "t:\(string)"
            case .button(let title, _): return "b:\(title)"
            }
        }.joined(separator: "|")
    }
}
#endif
