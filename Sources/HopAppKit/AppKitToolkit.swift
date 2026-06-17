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

/// Bridges `NSTextField`'s live-edit notifications to a stored Swift closure.
public final class TextFieldDelegate: NSObject, NSTextFieldDelegate {
    var onChange: (@MainActor (String) -> Void)?
    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        onChange?(field.stringValue)
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
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("HopOutlineCell")
        let field: NSTextField
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
        }
        field.stringValue = (item as? Item)?.node.title ?? ""
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
            return AppKitWidget(HopLabel(labelWithString: ""))
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
            // Unknown key (e.g. a self-hosting component that reached here without a renderer): a plain layer.
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
            label.alignment = .center
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
        if (patch.font != nil || patch.fontWeight != nil), let label = handle.view as? NSTextField {
            label.font = Self.nsFont(patch.font, weight: patch.fontWeight, current: label.font)
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
    }

    private static func nsColor(_ color: Color) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.opacity)
    }

    private static func nsFont(_ font: Font?, weight: Font.Weight?, current: NSFont?) -> NSFont {
        let size = font.map { CGFloat($0.size) } ?? (current?.pointSize ?? NSFont.systemFontSize)
        // A named family ignores the weight override (weight is selected by the family name on macOS).
        if let family = font?.family, let named = NSFont(name: family, size: size) {
            return named
        }
        let resolved = weight ?? font?.weight ?? .regular
        return NSFont.systemFont(ofSize: size, weight: nsWeight(resolved))
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

    // MARK: - Framework-owned layout

    public func setFrame(_ handle: AppKitWidget, _ rect: CGRect) {
        // Parents are flipped (top-left origin), so the engine's top-left rect maps directly.
        handle.view.frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        // NSTabView sizes the selected page's view lazily; force it now so the engine reads the page's
        // content rect (via sizeOf) in this same layout pass and centers the page content correctly.
        if handle.view is NSTabView { handle.view.layoutSubtreeIfNeeded() }
    }

    public func measure(_ handle: AppKitWidget, _ proposal: ProposedViewSize) -> CGSize {
        // Shapes are greedy: they fill whatever they're offered (default 100×100 when unspecified).
        if handle.view is HopShapeView { return proposal.resolved(CGSize(width: 100, height: 100)) }
        // Images: natural pixel size, unless `.resizable()` (then greedy, filling the offered frame).
        if let imageView = handle.view as? HopImageView {
            let natural = imageView.image?.size ?? CGSize(width: 24, height: 24)
            return imageView.isResizable ? proposal.resolved(natural) : natural
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

        if let fill = spec.fill {
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

    public func run(title: String, onReady: @escaping @MainActor (AppKitWidget) -> Void) {
        installAppKitMainExecutor()  // route hopTask onto the main run loop
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // A flipped content view so the layout engine's top-left origin maps directly to AppKit frames.
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 820, height: 760))
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
        let signature = toolbarSignature(items)
        guard signature != self.toolbarSignature else { return }
        self.toolbarSignature = signature

        toolbarController.itemsByID = [:]
        toolbarController.identifiers = []
        toolbarController.trampolines = []
        for (index, spec) in items.enumerated() {
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

        let toolbar = NSToolbar(identifier: "HopToolbar")
        toolbar.delegate = toolbarController
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window?.toolbar = toolbar
        if #available(macOS 11.0, *) { window?.toolbarStyle = .unified }
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
