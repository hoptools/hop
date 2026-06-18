// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import CQt
import HopUI
import Foundation  // Date (for DatePicker value conversion)
#if canImport(Darwin)
import Darwin  // strdup
#elseif canImport(Glibc)
import Glibc
#endif

/// Opaque handle wrapping a `QWidget *` (and, for interactive widgets, its callback box).
public final class QtWidget {
    let ptr: UnsafeMutableRawPointer
    var actionBox: QtActionBox?
    var isSplit = false
    var isWindow = false
    var isFixed = false  // an absolute-positioning container the layout engine drives
    var isScroll = false  // a QScrollArea viewport
    var isScrollContent = false  // the QScrollArea's single content widget (sized, not positioned, by the engine)
    var isShape = false
    var isToggle = false
    var isTabView = false
    var isImage = false
    var imageResizable = false
    var isProgress = false
    var isLabel = false   // a QLabel (Text) — measured with width-for-wrap
    var flexibleWidth = false  // text fields / sliders / progress bars fill the offered width (SwiftUI-like)
    // Guards re-entrant file-dialog presentation (a nested modal event loop can re-run a flush).
    var importerPresenting = false
    var exporterPresenting = false
    var scrollHandler: (@MainActor (CGSize) -> Void)?
    var scrollConnected = false
    var lastFrame: CGRect?  // last frame applied by setFrame; skip redundant geometry calls (keeps scroll momentum)
    // Action boxes for a drop-down menu's items, retained so their C callbacks stay valid.
    var retainedBoxes: [QtActionBox] = []
    // For `.onTapGesture`: the retained callback box + the installed event filter (so we can remove it).
    var tapBox: QtActionBox?
    var tapFilter: UnsafeMutableRawPointer?
    init(_ ptr: UnsafeMutableRawPointer) { self.ptr = ptr }
}

/// Holds a widget's Swift callbacks so the C++ signal lambda can reach them via a `user_data`
/// pointer. The owning ``QtWidget`` retains it, so it is passed unretained across the boundary.
final class QtActionBox {
    var action: (@MainActor () -> Void)?
    var onChange: (@MainActor (String) -> Void)?
    var onChangeDouble: (@MainActor (Double) -> Void)?
    var onChangeBool: (@MainActor (Bool) -> Void)?
    var lastBool: Bool?
    var onSelectTab: (@MainActor (Int) -> Void)?
    var lastTab: Int?
    var tabConnected = false
    var rowText: (@MainActor (Int) -> String)?
    var onSelect: (@MainActor (Int?) -> Void)?
    var listCount = -1
    var lastSelected: Int?
    /// Picker selection callback, its option labels (for change detection), and whether the combo's
    /// signal is wired.
    var pickerOnSelect: (@MainActor (Int) -> Void)?
    var pickerOptions: [String] = []
    var comboConnected = false
    /// Date-picker change callback (called with Unix seconds). The shim blocks the signal during
    /// programmatic sets, so no feedback-loop guard is needed here.
    var onChangeDate: (@MainActor (Double) -> Void)?
    /// Color-picker change callback (RGBA, each 0..1). Only fires on a user pick (programmatic set is silent).
    var onChangeColor: (@MainActor (Double, Double, Double, Double) -> Void)?
    /// Outline (tree) state: the flattened rows the C row callbacks read, a structure signature for
    /// rebuild detection, the last reflected selection key, whether the selection signal is wired, and the
    /// key→selection callback.
    var treeFlat: [(key: String, title: String, depth: Int, selectable: Bool)] = []
    var treeSignature: String?
    var lastSelectedKey: String?
    var treeConnected = false
    var onSelectKey: (@MainActor (String?) -> Void)?
    /// Keys of non-selectable group-header rows, plus the owning QTreeWidget pointer, so the selection
    /// callback can revert a header click back to the last valid selection.
    var headerKeys: Set<String> = []
    var treePtr: UnsafeMutableRawPointer?
    /// Current shape to draw, read by the QWidget paint callback (for `.shape` widgets).
    var shape: ShapeSpec?
    /// Layout frame size (from `.frame`) and the transform bleed offset, so the paint callback can paint
    /// the frame-sized shape at the right spot within the (possibly enlarged) widget.
    var frameWidth: Double = 0
    var frameHeight: Double = 0
    var bleedX: Double = 0
    var bleedY: Double = 0
}

/// Carries a QPainter pointer into the main-thread draw closure. Qt invokes paintEvent on the GUI
/// thread, so the crossing is safe.
private struct SendableQtPainter: @unchecked Sendable {
    let ptr: UnsafeMutableRawPointer
}

// Non-capturing C callbacks; context arrives through `user_data` and is recovered via `Unmanaged`.
// Qt invokes these on the main thread, so we assert main-actor isolation to touch HopUI state.

private let qtClickCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
    guard let userData else { return }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.action?() }
}

private let qtChangedCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { text, userData in
    guard let text, let userData else { return }
    let value = String(cString: text)
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onChange?(value) }
}

private let qtSliderCallback: @convention(c) (Double, UnsafeMutableRawPointer?) -> Void = { value, userData in
    guard let userData else { return }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onChangeDouble?(value) }
}

// Fired by QDateTimeEdit with the new value as Unix seconds (only on user edits — programmatic sets are
// signal-blocked in the shim).
private let qtDateCallback: @convention(c) (Double, UnsafeMutableRawPointer?) -> Void = { value, userData in
    guard let userData else { return }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onChangeDate?(value) }
}

// Fired when the user picks a color in the QColorDialog opened by the swatch button (RGBA, each 0..1).
private let qtColorCallback: @convention(c) (Double, Double, Double, Double, UnsafeMutableRawPointer?) -> Void = { r, g, b, a, userData in
    guard let userData else { return }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onChangeColor?(r, g, b, a) }
}

// QCheckBox toggled(bool), passed as 0/1, for a Toggle.
private let qtSwitchCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { value, userData in
    guard let userData else { return }
    let on = value != 0
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if box.lastBool != on {
            box.lastBool = on
            box.onChangeBool?(on)
        }
    }
}

// Returns a malloc'd C string for the row; the Qt shim frees it after copying into a QString.
private let qtRowCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? = { position, userData in
    guard let userData else { return nil }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    let text = MainActor.assumeIsolated { box.rowText?(Int(position)) ?? "" }
    return strdup(text)
}

private let qtListSelectionCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { value, userData in
    guard let userData else { return }
    let index: Int? = value < 0 ? nil : Int(value)
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if box.lastSelected != index {
            box.lastSelected = index
            box.onSelect?(index)
        }
    }
}

// Outline row callbacks: title / key (malloc'd; the shim frees) and depth for a flattened tree row.
private let qtTreeTitleCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? = { position, userData in
    guard let userData else { return nil }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    let title = MainActor.assumeIsolated { box.treeFlat.indices.contains(Int(position)) ? box.treeFlat[Int(position)].title : "" }
    return strdup(title)
}
private let qtTreeKeyCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? = { position, userData in
    guard let userData else { return nil }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    let key = MainActor.assumeIsolated { box.treeFlat.indices.contains(Int(position)) ? box.treeFlat[Int(position)].key : "" }
    return strdup(key)
}
private let qtTreeDepthCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32 = { position, userData in
    guard let userData else { return 0 }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated { Int32(box.treeFlat.indices.contains(Int(position)) ? box.treeFlat[Int(position)].depth : 0) }
}
private let qtTreeSelectableCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32 = { position, userData in
    guard let userData else { return 1 }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated { (box.treeFlat.indices.contains(Int(position)) ? box.treeFlat[Int(position)].selectable : true) ? 1 : 0 }
}

// QTreeWidget selection callback (currentItemChanged): reports the newly-selected row's key (or nil).
private let qtTreeSelectionCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { cKey, userData in
    guard let userData else { return }
    let key: String? = cKey.map { String(cString: $0) }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        // A non-selectable group header was clicked: revert to the last valid selection (via setCurrentItem,
        // which doesn't re-fire itemClicked) rather than report the header.
        if let key, box.headerKeys.contains(key), let tree = box.treePtr {
            hopqt_tree_select_key(tree, box.lastSelectedKey)
            return
        }
        if box.lastSelectedKey != key {
            box.lastSelectedKey = key
            box.onSelectKey?(key)
        }
    }
}

// QTabWidget currentChanged: report the newly-selected tab index. user_data is the action box.
private let qtTabCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { value, userData in
    guard let userData else { return }
    let index = Int(value)
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if box.lastTab != index {
            box.lastTab = index
            box.onSelectTab?(index)
        }
    }
}

// Button-group (Picker .segmented / .radioGroup) selection callback: the clicked button's index.
private let qtButtonGroupCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { value, userData in
    guard let userData else { return }
    let index = Int(value)
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if box.lastSelected != index {
            box.lastSelected = index
            if index >= 0 { box.pickerOnSelect?(index) }
        }
    }
}

// QComboBox selection callback (currentIndexChanged): reports the newly-selected index for a Picker.
private let qtComboCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { value, userData in
    guard let userData else { return }
    let index = Int(value)
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if box.lastSelected != index {
            box.lastSelected = index
            if index >= 0 { box.pickerOnSelect?(index) }
        }
    }
}

// QWidget paint callback: (painter, width, height, user_data). Recovers the shape spec from the
// action box and paints it with QPainter on the main thread.
private let qtPaintCallback: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Void = { painter, width, height, userData in
    guard let painter, let userData else { return }
    let box = Unmanaged<QtActionBox>.fromOpaque(userData).takeUnretainedValue()
    let wrapped = SendableQtPainter(ptr: painter)
    MainActor.assumeIsolated {
        guard let spec = box.shape else { return }
        // Fall back to the widget size when no explicit frame was given.
        let frameW = box.frameWidth > 0 ? box.frameWidth : Double(width)
        let frameH = box.frameHeight > 0 ? box.frameHeight : Double(height)
        QtToolkit.drawShape(spec, frameWidth: frameW, frameHeight: frameH,
                            bleedX: box.bleedX, bleedY: box.bleedY, painter: wrapped.ptr)
    }
}

// Root-container resize: re-run the layout engine. user_data is the toolkit.
private let qtResizeCallback: @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void = { _, _, userData in
    guard let userData else { return }
    let toolkit = Unmanaged<QtToolkit>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { toolkit.relayoutHandler?() }
}

// QScrollArea scrollbar value-changed: report the new offset so virtualized content re-materializes.
// user_data is the scroll QtWidget handle; args are (xOffset, yOffset).
private let qtScrollCallback: @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void = { x, y, userData in
    guard let userData else { return }
    let handle = Unmanaged<QtWidget>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { handle.scrollHandler?(CGSize(width: Double(x), height: Double(y))) }
}

/// Holds a one-shot main-thread closure for the Qt posted-callback to invoke.
final class QtMainThunk {
    let work: @MainActor () -> Void
    init(_ work: @escaping @MainActor () -> Void) { self.work = work }
}

private let qtPostCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
    guard let userData else { return }
    let thunk = Unmanaged<QtMainThunk>.fromOpaque(userData).takeRetainedValue()
    MainActor.assumeIsolated { thunk.work() }
}

/// Qt toolkit: maps HopUI widgets onto QWidget/QVBoxLayout/QHBoxLayout/QLabel/QPushButton/QLineEdit
/// and runs the QApplication event loop. Uses the locally-installed Homebrew Qt6 via the CQt shim.
public final class QtToolkit: AppToolkit {
    public typealias Handle = QtWidget

    private var app: UnsafeMutableRawPointer?
    private var window: UnsafeMutableRawPointer?
    private var toolbar: UnsafeMutableRawPointer?
    private var toolbarBoxes: [QtActionBox] = []
    private var toolbarSignature: String?
    private var menuBoxes: [QtActionBox] = []
    private var menuSignature: String?
    // Secondary windows (e.g. About) are kept here for the app's lifetime.
    private var secondaryWindows: [UnsafeMutableRawPointer] = []
    // The root absolute-positioning container filling the window; its size is the layout root proposal.
    var rootContainer: UnsafeMutableRawPointer?
    // Called by the runtime to re-run the layout engine when the window content size changes.
    var relayoutHandler: (@MainActor () -> Void)?

    // MARK: - Open component system
    public static let toolkitID = ToolkitID.qt
    public let components = ComponentRegistry<QtWidget>()

    public init() { registerBuiltinComponents() }

    public func realize(_ component: any WidgetComponent) -> QtWidget {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.make(component) }
        if let ptr = component.makeNative(Self.toolkitID) as? UnsafeMutableRawPointer { return QtWidget(ptr) }
        assertionFailure("HopUI/Qt: no renderer registered for WidgetKey \"\(component.widgetKey.rawValue)\", and the component self-hosts no QWidget")
        return makeNativeWidget(.vstack)
    }

    public func updateComponent(_ handle: QtWidget, _ component: any WidgetComponent) {
        if let renderer = components.renderer(for: component.widgetKey) { renderer.update(handle, component); return }
        component.updateNative(handle.ptr, Self.toolkitID)
    }

    public func measureComponent(_ handle: QtWidget, _ component: any WidgetComponent, _ proposal: ProposedViewSize) -> CGSize {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.measure(handle, component, proposal) }
        switch component.role {
        case .fill, .native: return proposal.resolved(.zero)
        default: return measure(handle, proposal)
        }
    }

    public func didInsertChildren(_ handle: QtWidget, _ component: any WidgetComponent) {
        components.renderer(for: component.widgetKey)?.afterChildren?(handle, component)
    }

    private func registerBuiltinComponents() {
        registerLeafComponents()
        registerSpecLeafComponents()
        registerContainerComponents()
        registerNativeCompositeComponents()
        registerImageComponent()
        registerPickerComponents()
    }

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

    private func applyLeaf(_ handle: QtWidget, _ component: any WidgetComponent) {
        guard let leaf = component as? PrimitiveLeafComponent else { return }
        configure(handle, leaf.patch)
        setAction(handle, leaf.action)
        setTextHandler(handle, leaf.onChange)
        setValueHandler(handle, leaf.onChangeDouble)
        setBoolHandler(handle, leaf.onChangeBool)
    }

    /// `Picker` renderers — each style is a distinct native widget under its own key. `.menu`/`.automatic`
    /// → QComboBox; `.segmented` → a horizontal row of checkable buttons; `.radioGroup` → a vertical group
    /// of radio buttons. The reconciler recreates the widget when the style changes.
    private func registerPickerComponents() {
        let combo = ComponentRegistry<QtWidget>.Renderer(
            make: { [unowned self] component in
                let handle = makeNativeWidget(.picker)
                if let spec = (component as? PickerComponent)?.spec { configurePicker(handle, spec) }
                return handle
            },
            update: { [unowned self] handle, component in
                if let spec = (component as? PickerComponent)?.spec { configurePicker(handle, spec) }
            },
            measure: { [unowned self] handle, _, proposal in measure(handle, proposal) })
        components.register(combo, for: .picker(.menu))
        components.register(combo, for: .picker(.automatic))

        for (style, horizontal, toggle) in [(PickerStyle.segmented, true, true), (PickerStyle.radioGroup, false, false)] {
            components.register(.init(
                make: { [unowned self] component in
                    let handle = QtWidget(hopqt_buttongroup_new(horizontal ? 1 : 0)!)
                    handle.actionBox = QtActionBox()
                    if let spec = (component as? PickerComponent)?.spec { configureButtonGroupPicker(handle, spec, toggle: toggle) }
                    return handle
                },
                update: { [unowned self] handle, component in
                    if let spec = (component as? PickerComponent)?.spec { configureButtonGroupPicker(handle, spec, toggle: toggle) }
                },
                measure: { [unowned self] handle, _, proposal in measure(handle, proposal) }
            ), for: .picker(style))
        }
    }

    /// Configure a segmented / radio-group picker: (re)populate when the options change, otherwise reflect
    /// the bound selection. `toggle` selects checkable push buttons (segmented) vs radio buttons.
    private func configureButtonGroupPicker(_ handle: QtWidget, _ spec: PickerSpec, toggle: Bool) {
        guard let box = handle.actionBox else { return }
        box.pickerOnSelect = spec.onSelect
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        if box.pickerOptions != spec.options {
            box.pickerOptions = spec.options
            box.rowText = { spec.options[$0] }
            hopqt_buttongroup_set_items(handle.ptr, Int32(spec.options.count), qtRowCallback,
                                        Int32(spec.selectedIndex ?? -1), toggle ? 1 : 0, qtButtonGroupCallback, boxPtr)
            box.lastSelected = spec.selectedIndex
        } else if box.lastSelected != spec.selectedIndex {
            box.lastSelected = spec.selectedIndex
            hopqt_buttongroup_set_selected(handle.ptr, Int32(spec.selectedIndex ?? -1))
        }
    }

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

    public func makeNativeWidget(_ key: WidgetKey) -> QtWidget {
        switch key {
        case .vstack, .hstack, .zstack, .spacer, .window, .geometry, .lazyStack:
            // Box-model containers are absolute-positioning layers; the layout engine owns geometry.
            let widget = QtWidget(hopqt_fixed_new()!)
            widget.isFixed = true
            return widget
        case .groupBox:
            let widget = QtWidget(hopqt_fixed_new()!)
            widget.isFixed = true
            hopqt_widget_make_card(widget.ptr)  // rounded/bordered/filled card chrome
            return widget
        case .scroll:
            // A real clipping/scrolling viewport; its single content child scrolls within it.
            let widget = QtWidget(hopqt_scrollarea_new()!)
            widget.isScroll = true
            return widget
        case .label:
            let widget = QtWidget(hopqt_label_new("")!)
            widget.isLabel = true   // measured with width-for-wrap (QLabel wraps like SwiftUI Text)
            return widget
        case .button:
            let widget = QtWidget(hopqt_button_new("")!)
            let box = QtActionBox()
            widget.actionBox = box
            hopqt_button_connect(widget.ptr, qtClickCallback, Unmanaged.passUnretained(box).toOpaque())
            return widget
        case .textField:
            let widget = QtWidget(hopqt_lineedit_new("")!)
            widget.flexibleWidth = true
            let box = QtActionBox()
            widget.actionBox = box
            hopqt_lineedit_connect(widget.ptr, qtChangedCallback, Unmanaged.passUnretained(box).toOpaque())
            return widget
        case .secureField:
            let widget = QtWidget(hopqt_lineedit_new("")!)
            hopqt_lineedit_set_password(widget.ptr, 1)  // mask typed characters
            widget.flexibleWidth = true
            let box = QtActionBox()
            widget.actionBox = box
            hopqt_lineedit_connect(widget.ptr, qtChangedCallback, Unmanaged.passUnretained(box).toOpaque())
            return widget
        case .toggle:
            let widget = QtWidget(hopqt_switch_new()!)
            widget.isToggle = true
            let box = QtActionBox()
            widget.actionBox = box
            hopqt_switch_connect(widget.ptr, qtSwitchCallback, Unmanaged.passUnretained(box).toOpaque())
            return widget
        case .slider:
            let widget = QtWidget(hopqt_slider_new(0, 1)!)
            widget.flexibleWidth = true
            let box = QtActionBox()
            widget.actionBox = box
            hopqt_slider_connect(widget.ptr, qtSliderCallback, Unmanaged.passUnretained(box).toOpaque())
            return widget
        case .datePicker:
            let widget = QtWidget(hopqt_datetime_new()!)
            let box = QtActionBox()
            widget.actionBox = box
            hopqt_datetime_connect(widget.ptr, qtDateCallback, Unmanaged.passUnretained(box).toOpaque())
            return widget
        case .colorPicker:
            let widget = QtWidget(hopqt_colorwell_new()!)
            let box = QtActionBox()
            widget.actionBox = box
            hopqt_colorwell_connect(widget.ptr, qtColorCallback, Unmanaged.passUnretained(box).toOpaque())
            return widget
        case .list, .sidebarList:
            let widget = QtWidget(hopqt_list_new()!)
            if key == .sidebarList { hopqt_list_set_sidebar(widget.ptr, 1) }  // source-list styling at creation
            widget.actionBox = QtActionBox()  // selection connected in configureList after the model is set
            return widget
        case .outline, .sidebarOutline:
            let widget = QtWidget(hopqt_tree_new()!)
            if key == .sidebarOutline { hopqt_tree_set_sidebar(widget.ptr, 1) }  // source-list styling at creation
            widget.actionBox = QtActionBox()  // selection connected in configureOutline
            return widget
        case .image:
            let widget = QtWidget(hopqt_imageview_new()!)
            widget.isImage = true
            return widget
        case .tabView:
            let widget = QtWidget(hopqt_tabwidget_new()!)
            widget.isTabView = true
            widget.actionBox = QtActionBox()  // currentChanged connected in configureTabs
            return widget
        case .splitView:
            let widget = QtWidget(hopqt_splitter_new()!)
            widget.isSplit = true
            return widget
        case .shape:
            let box = QtActionBox()
            let widget = QtWidget(hopqt_shape_new(qtPaintCallback, Unmanaged.passUnretained(box).toOpaque())!)
            widget.actionBox = box
            widget.isShape = true
            return widget
        case .menu:
            return QtWidget(hopqt_menubutton_new("")!)
        case .picker:
            let widget = QtWidget(hopqt_combo_new()!)
            widget.actionBox = QtActionBox()  // selection signal connected in configurePicker
            return widget
        case .separator:
            return QtWidget(hopqt_separator_new()!)
        case .progress:
            let widget = QtWidget(hopqt_progress_new()!)
            widget.isProgress = true
            widget.flexibleWidth = true
            return widget
        default:
            // Only registered renderers call this, with keys this switch knows — an unknown key is a bug.
            assertionFailure("HopUI/Qt: makeNativeWidget has no native widget for key \"\(key.rawValue)\"")
            let widget = QtWidget(hopqt_fixed_new()!)  // degrade to a plain layer in release
            widget.isFixed = true
            return widget
        }
    }

    public func configure(_ handle: QtWidget, _ patch: WidgetPatch) {
        if let text = patch.text { hopqt_label_set_text(handle.ptr, text) }
        if let title = patch.title { hopqt_button_set_text(handle.ptr, title) }
        if let placeholder = patch.placeholder { hopqt_lineedit_set_placeholder(handle.ptr, placeholder) }
        if let value = patch.value {
            // Guard against resetting the text (and the cursor) to what's already shown, which also
            // prevents a feedback loop when our own edit triggers a re-render.
            let current = hopqt_lineedit_text(handle.ptr).map { String(cString: $0) } ?? ""
            if current != value { hopqt_lineedit_set_text(handle.ptr, value) }
        }
        if let minV = patch.minValue, let maxV = patch.maxValue {
            hopqt_slider_set_range(handle.ptr, minV, maxV)
        }
        if let v = patch.doubleValue {
            hopqt_slider_set_value(handle.ptr, v)  // guards against feedback loops internally
        }
        if handle.isToggle, let on = patch.boolValue {
            if (hopqt_switch_checked(handle.ptr) != 0) != on {
                handle.actionBox?.lastBool = on
                hopqt_switch_set_checked(handle.ptr, on ? 1 : 0)
            }
        }
        if let css = Self.styleSheet(patch) { hopqt_widget_set_style(handle.ptr, css) }

        // Progress bar: a fraction is determinate; nil shows Qt's built-in indeterminate busy animation.
        if handle.isProgress {
            if let value = patch.progressValue {
                hopqt_progress_set_fraction(handle.ptr, value)
            } else {
                hopqt_progress_set_indeterminate(handle.ptr)
            }
        }

        // Accessibility → QAccessible (name/description) + objectName as the test identifier.
        if let label = patch.accessibilityLabel { hopqt_set_accessible_name(handle.ptr, label) }
        if let description = patch.accessibilityHint ?? patch.accessibilityValue {
            hopqt_set_accessible_description(handle.ptr, description)
        }
        if let identifier = patch.accessibilityIdentifier { hopqt_set_object_name(handle.ptr, identifier) }
    }

    /// Builds an inline Qt stylesheet (bare properties applied to the widget) for the patch's styling.
    private static func styleSheet(_ patch: WidgetPatch) -> String? {
        var rules: [String] = []
        if let fg = patch.foregroundColor { rules.append("color: \(fg.cssRGBA)") }
        if let bg = patch.backgroundColor { rules.append("background-color: \(bg.cssRGBA)") }
        if let font = patch.font {
            rules.append("font-size: \(Int(font.size.rounded()))px")
            if let family = font.family { rules.append("font-family: \"\(family)\"") }
        }
        if let weight = patch.fontWeight ?? patch.font?.weight {
            rules.append("font-weight: \(weight.cssValue)")
        }
        guard !rules.isEmpty else { return nil }
        return rules.joined(separator: "; ") + ";"
    }

    public func insert(_ child: QtWidget, into parent: QtWidget, at index: Int) {
        if parent.isScroll {
            child.isScrollContent = true  // sized (not positioned) by the engine; the area owns scroll
            hopqt_scrollarea_set_content(parent.ptr, child.ptr)
            return
        }
        if parent.isSplit {
            hopqt_splitter_add(parent.ptr, child.ptr)
            if index == 1 { hopqt_splitter_set_sizes(parent.ptr, 260, 560) }
            return
        }
        if parent.isTabView {
            hopqt_tabwidget_add(parent.ptr, child.ptr, "")  // titles set in configureTabs
            return
        }
        if parent.isFixed {
            // Absolute container: the engine repositions via setFrame; child add order is z-order.
            hopqt_fixed_add(parent.ptr, child.ptr)
        } else {
            // A native box (e.g. a secondary window's content): insert at the requested index.
            hopqt_box_insert(parent.ptr, child.ptr, Int32(index))
        }
    }

    public func move(_ child: QtWidget, in parent: QtWidget, to index: Int) {
        guard !parent.isSplit, !parent.isScroll, !parent.isTabView else { return }  // pages don't reorder
        // A fixed parent has no child reorder; z-order rarely matters for non-overlapping layouts, and the
        // engine repositions every child each pass, so a fixed-parent move is a no-op in the MVP.
        if !parent.isFixed {
            hopqt_box_reorder(parent.ptr, child.ptr, Int32(index))
        }
    }

    public func remove(_ child: QtWidget, from parent: QtWidget) {
        if parent.isScroll {
            // The QScrollArea owns its single content widget; it's torn down with the area.
        } else if parent.isTabView {
            hopqt_tabwidget_remove(parent.ptr, child.ptr)
        } else if parent.isFixed {
            hopqt_fixed_remove(child.ptr)
        } else if !parent.isSplit {
            hopqt_box_remove(parent.ptr, child.ptr)
        }
    }

    public func setAction(_ handle: QtWidget, _ action: (@MainActor () -> Void)?) {
        handle.actionBox?.action = action
    }

    public func setTextHandler(_ handle: QtWidget, _ handler: (@MainActor (String) -> Void)?) {
        handle.actionBox?.onChange = handler
    }

    public func setValueHandler(_ handle: QtWidget, _ handler: (@MainActor (Double) -> Void)?) {
        handle.actionBox?.onChangeDouble = handler
    }

    public func setBoolHandler(_ handle: QtWidget, _ handler: (@MainActor (Bool) -> Void)?) {
        handle.actionBox?.onChangeBool = handler
    }

    public func configureList(_ handle: QtWidget, _ spec: ListSpec) {
        guard let box = handle.actionBox else { return }
        box.rowText = spec.rowText
        box.onSelect = spec.onSelect
        if box.listCount != spec.count {
            box.listCount = spec.count
            let boxPtr = Unmanaged.passUnretained(box).toOpaque()
            hopqt_list_set_model(handle.ptr, Int32(spec.count), qtRowCallback, boxPtr)
            hopqt_list_connect_selection(handle.ptr, qtListSelectionCallback, boxPtr)
        }
        let target = spec.selectedIndex
        let current = Int(hopqt_list_selected(handle.ptr))
        let currentIndex: Int? = current < 0 ? nil : current
        if currentIndex != target {
            box.lastSelected = target
            hopqt_list_set_selected(handle.ptr, Int32(target ?? -1))
        }
    }

    public func configureOutline(_ handle: QtWidget, _ spec: OutlineSpec) {
        guard let box = handle.actionBox else { return }
        let flat = spec.flattened()
        // The toolkit carries only string keys natively, so map each key back to its original AnyHashable
        // id to preserve the binding's selection type (the List does `id.base as? SelectionValue`).
        let idByKey = Dictionary(flat.map { ($0.node.key, $0.node.id) }, uniquingKeysWith: { first, _ in first })
        box.onSelectKey = { key in spec.onSelect(key.flatMap { idByKey[$0] }) }
        box.headerKeys = Set(flat.filter { !$0.node.selectable }.map { $0.node.key })
        box.treePtr = handle.ptr

        // Rebuild the native tree only when the structure changes (the QTreeWidget is stable across
        // rebuilds, so the selection signal is connected just once).
        let signature = spec.structureSignature
        if box.treeSignature != signature {
            box.treeSignature = signature
            box.treeFlat = flat.map { (key: $0.node.key, title: $0.node.title, depth: $0.depth, selectable: $0.node.selectable) }
            let boxPtr = Unmanaged.passUnretained(box).toOpaque()
            hopqt_tree_set_rows(handle.ptr, Int32(flat.count),
                                qtTreeTitleCallback, qtTreeKeyCallback, qtTreeDepthCallback,
                                qtTreeSelectableCallback, boxPtr)
            if !box.treeConnected {
                hopqt_tree_connect_selection(handle.ptr, qtTreeSelectionCallback, boxPtr)
                box.treeConnected = true
            }
        }

        // Reflect the bound selection.
        let targetKey = spec.selectedID.map { "\($0.base)" }
        let currentKey = hopqt_tree_selected_key(handle.ptr).map { p -> String in
            let s = String(cString: p); free(p); return s
        }
        if currentKey != targetKey {
            box.lastSelectedKey = targetKey
            if let targetKey { hopqt_tree_select_key(handle.ptr, targetKey) }
            else { hopqt_tree_select_key(handle.ptr, nil) }
        }
    }

    public func configureTabs(_ handle: QtWidget, _ spec: TabSpec) {
        guard let box = handle.actionBox else { return }
        box.onSelectTab = spec.onSelect
        for (index, title) in spec.titles.enumerated() {
            hopqt_tabwidget_set_tab_text(handle.ptr, Int32(index), title)
        }
        if !box.tabConnected {
            box.tabConnected = true
            hopqt_tabwidget_connect(handle.ptr, qtTabCallback, Unmanaged.passUnretained(box).toOpaque())
        }
        let current = Int(hopqt_tabwidget_current(handle.ptr))
        if current != spec.selectedIndex {
            box.lastTab = spec.selectedIndex
            hopqt_tabwidget_set_current(handle.ptr, Int32(spec.selectedIndex))
        }
    }

    public func configureMenu(_ handle: QtWidget, _ menu: MenuContent) {
        hopqt_button_set_text(handle.ptr, menu.label)  // the menu button is a QPushButton
        guard let qmenu = hopqt_menubutton_menu(handle.ptr) else { return }
        hopqt_menu_clear(qmenu)
        var boxes: [QtActionBox] = []
        buildQtMenu(menu.entries, into: qmenu, boxes: &boxes)
        handle.retainedBoxes = boxes
    }

    /// Build a QMenu from entries (clearing deletes old QActions); buttons connect via `qtClickCallback`.
    private func buildQtMenu(_ entries: [MenuEntry], into qmenu: UnsafeMutableRawPointer, boxes: inout [QtActionBox]) {
        for entry in entries {
            switch entry {
            case .separator:
                hopqt_menu_add_separator(qmenu)
            case .button(let title, let action):
                let box = QtActionBox()
                box.action = action
                boxes.append(box)
                hopqt_menu_add_button(qmenu, title, qtClickCallback, Unmanaged.passUnretained(box).toOpaque())
            case .submenu(let title, let subEntries):
                if let submenu = hopqt_menu_add_submenu(qmenu, title) {
                    buildQtMenu(subEntries, into: submenu, boxes: &boxes)
                }
            }
        }
    }

    public func configurePicker(_ handle: QtWidget, _ spec: PickerSpec) {
        guard let box = handle.actionBox else { return }
        box.pickerOnSelect = spec.onSelect
        if box.pickerOptions != spec.options {
            box.pickerOptions = spec.options
            box.rowText = { spec.options[$0] }
            let boxPtr = Unmanaged.passUnretained(box).toOpaque()
            hopqt_combo_set_items(handle.ptr, Int32(spec.options.count), qtRowCallback, boxPtr)
            if !box.comboConnected {
                hopqt_combo_connect(handle.ptr, qtComboCallback, boxPtr)
                box.comboConnected = true
            }
        }
        let target = spec.selectedIndex
        let current = Int(hopqt_combo_selected(handle.ptr))
        let currentIndex: Int? = current < 0 ? nil : current
        if currentIndex != target {
            box.lastSelected = target
            hopqt_combo_set_selected(handle.ptr, Int32(target ?? -1))
        }
    }

    public func configureDatePicker(_ handle: QtWidget, _ spec: DatePickerSpec) {
        guard let box = handle.actionBox else { return }
        box.onChangeDate = { spec.onChange(Date(timeIntervalSince1970: $0)) }
        let wantDate = spec.components.contains(.date)
        let wantTime = spec.components.contains(.hourAndMinute)
        // QDateTimeEdit is inherently compact; the calendar popup covers the "graphical" intent too.
        hopqt_datetime_set_components(handle.ptr, wantDate ? 1 : 0, wantTime ? 1 : 0)
        hopqt_datetime_set_range(handle.ptr,
                                 spec.minDate != nil ? 1 : 0, spec.minDate?.timeIntervalSince1970 ?? 0,
                                 spec.maxDate != nil ? 1 : 0, spec.maxDate?.timeIntervalSince1970 ?? 0)
        // Programmatic set is signal-blocked in the shim, so this won't re-fire the change handler.
        hopqt_datetime_set(handle.ptr, spec.date.timeIntervalSince1970)
    }

    public func configureColorPicker(_ handle: QtWidget, _ spec: ColorPickerSpec) {
        guard let box = handle.actionBox else { return }
        box.onChangeColor = { r, g, b, a in spec.onChange(Color(red: r, green: g, blue: b, opacity: a)) }
        hopqt_colorwell_set_alpha(handle.ptr, spec.supportsOpacity ? 1 : 0)
        // Programmatic set never opens the dialog / fires the callback, so no loop.
        hopqt_colorwell_set(handle.ptr, spec.color.red, spec.color.green, spec.color.blue, spec.color.opacity)
    }

    /// A Qt filter string ("Name (*.ext);;All Files (*)") for a set of content types.
    private func qtFilter(_ types: [UTType]) -> String {
        var parts: [String] = []
        for t in types where !t.filenameExtensions.isEmpty {
            let globs = t.filenameExtensions.map { "*.\($0)" }.joined(separator: " ")
            parts.append("\(t.displayName) (\(globs))")
        }
        parts.append("All Files (*)")
        return parts.joined(separator: ";;")
    }

    public func configureFileImporter(_ handle: QtWidget, _ spec: FileImporterSpec) {
        guard spec.isPresented else { handle.importerPresenting = false; return }
        guard !handle.importerPresenting else { return }
        handle.importerPresenting = true
        let result = hopqt_file_open(handle.ptr, spec.allowsMultipleSelection ? 1 : 0, qtFilter(spec.allowedContentTypes))
        handle.importerPresenting = false
        spec.setPresented(false)
        if let result {
            let urls = String(cString: result).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            free(result)
            if !urls.isEmpty { spec.onCompletion(.success(urls)) }
        }
    }

    public func configureFileExporter(_ handle: QtWidget, _ spec: FileExporterSpec) {
        guard spec.isPresented else { handle.exporterPresenting = false; return }
        guard !handle.exporterPresenting else { return }
        handle.exporterPresenting = true
        let result = hopqt_file_save(handle.ptr, spec.defaultFilename, qtFilter([spec.contentType]))
        handle.exporterPresenting = false
        spec.setPresented(false)
        if let result {
            let url = URL(fileURLWithPath: String(cString: result))
            free(result)
            do { try spec.data.write(to: url); spec.onCompletion(.success(url)) }
            catch { spec.onCompletion(.failure(error)) }
        }
    }

    public func configureShape(_ handle: QtWidget, _ spec: ShapeSpec) {
        guard let box = handle.actionBox else { return }
        box.shape = spec
        // Sizing/positioning (including transform-bleed enlargement) is applied in setFrame, once the
        // layout engine has chosen the shape's frame.
        hopqt_shape_update(handle.ptr)
    }

    public func configureImage(_ handle: QtWidget, _ spec: ImageSpec) {
        handle.imageResizable = spec.resizable
        switch spec.source {
        case .system(let name):
            hopqt_imageview_set_icon(handle.ptr, name)  // no SF Symbols on Qt → icon theme + fallback
        case .named, .file:
            if let url = spec.resolvedURL() { hopqt_imageview_set_file(handle.ptr, url.path) }
        case .data(let data):
            data.withUnsafeBytes { raw in
                hopqt_imageview_set_data(handle.ptr, raw.bindMemory(to: UInt8.self).baseAddress, Int32(data.count))
            }
        }
        // mode: 0=stretch 1=fit 2=fill (ignored when not resizable — drawn at natural size).
        let mode: Int32
        switch spec.contentMode {
        case .none: mode = 0
        case .fit:  mode = 1
        case .fill: mode = 2
        }
        hopqt_imageview_set_mode(handle.ptr, spec.resizable ? 1 : 0, mode)
    }

    // MARK: - Framework-owned layout

    public func setFrame(_ handle: QtWidget, _ rect: CGRect) {
        // Skip redundant geometry: the per-scroll re-render re-lays-out the whole tree, but during a scroll
        // only the newly-materialized rows actually move. Re-applying the scroll area's / content's
        // unchanged geometry every tick cancels Qt's in-flight trackpad momentum (its "fling"), so skip it.
        if handle.lastFrame == rect { return }
        handle.lastFrame = rect
        if handle.isShape, let box = handle.actionBox {
            // A QWidget clips painting to its bounds, so enlarge it to fit any transform overflow and
            // offset its origin by the bleed so the frame-sized shape still lands at (minX, minY).
            box.frameWidth = Double(rect.width)
            box.frameHeight = Double(rect.height)
            let bleed = box.shape.map { $0.transformBleed(width: rect.width, height: rect.height) }
            let left = Double(bleed?.left ?? 0), top = Double(bleed?.top ?? 0)
            let right = Double(bleed?.right ?? 0), bottom = Double(bleed?.bottom ?? 0)
            box.bleedX = left
            box.bleedY = top
            hopqt_widget_set_geometry(handle.ptr,
                Int32((Double(rect.minX) - left).rounded()), Int32((Double(rect.minY) - top).rounded()),
                Int32((Double(rect.width) + left + right).rounded(.up)),
                Int32((Double(rect.height) + top + bottom).rounded(.up)))
            hopqt_shape_update(handle.ptr)
        } else if handle.isScrollContent {
            // The QScrollArea positions this child (it offsets it as you scroll); only set its SIZE, so a
            // relayout (e.g. from the scroll feedback) doesn't reset the scroll position to the top.
            hopqt_widget_resize(handle.ptr,
                Int32(Double(rect.width).rounded()), Int32(Double(rect.height).rounded()))
        } else {
            hopqt_widget_set_geometry(handle.ptr,
                Int32(Double(rect.minX).rounded()), Int32(Double(rect.minY).rounded()),
                Int32(Double(rect.width).rounded()), Int32(Double(rect.height).rounded()))
        }
    }

    public func measure(_ handle: QtWidget, _ proposal: ProposedViewSize) -> CGSize {
        // Shapes are greedy: they fill whatever they're offered (default 100×100 when unspecified).
        if handle.isShape { return proposal.resolved(CGSize(width: 100, height: 100)) }
        // Images: natural pixel size, greedy when `.resizable()`.
        if handle.isImage {
            var iw: Int32 = 0, ih: Int32 = 0
            hopqt_image_natural_size(handle.ptr, &iw, &ih)
            let natural = CGSize(width: Double(iw), height: Double(ih))
            return handle.imageResizable ? proposal.resolved(natural) : natural
        }
        // A label (Text) wraps to the proposed width: report the wrapped height, not the single-line width.
        if handle.isLabel {
            var lw: Int32 = 0, lh: Int32 = 0
            let forWidth = (proposal.width?.isFinite == true) ? Int32(Swift.max(0, proposal.width!)) : -1
            hopqt_label_measure(handle.ptr, forWidth, &lw, &lh)
            return CGSize(width: Double(lw), height: Double(lh))
        }
        var w: Int32 = 0, h: Int32 = 0
        hopqt_widget_size_hint(handle.ptr, &w, &h)
        // Flexible-width controls (text fields, sliders, progress bars) expand to the offered width.
        if handle.flexibleWidth, let pw = proposal.width, pw.isFinite {
            return CGSize(width: Swift.max(pw, Double(w)), height: Double(h))
        }
        return CGSize(width: Double(w), height: Double(h))
    }

    public func sizeOf(_ handle: QtWidget) -> CGSize {
        var w: Int32 = 0, h: Int32 = 0
        hopqt_widget_size(handle.ptr, &w, &h)
        return CGSize(width: Double(w), height: Double(h))
    }

    public func setScrollHandler(_ handle: QtWidget, _ handler: (@MainActor (CGSize) -> Void)?) {
        handle.scrollHandler = handler
        // Connect the QScrollArea's scrollbars once, so user scrolls drive virtualized re-materialization.
        if handle.isScroll, !handle.scrollConnected, handler != nil {
            hopqt_scrollarea_connect_scroll(handle.ptr, qtScrollCallback, Unmanaged.passUnretained(handle).toOpaque())
            handle.scrollConnected = true
        }
    }

    public func setTapHandler(_ handle: QtWidget, _ spec: TapGestureSpec?) {
        if let filter = handle.tapFilter {
            hopqt_tap_remove(handle.ptr, filter)
            handle.tapFilter = nil; handle.tapBox = nil
        }
        guard let spec else { return }
        let box = QtActionBox()
        box.action = spec.action
        handle.tapBox = box   // retain so the C callback's user_data stays valid
        handle.tapFilter = hopqt_tap_install(handle.ptr, Int32(Swift.max(1, spec.count)), qtClickCallback,
                                             Unmanaged.passUnretained(box).toOpaque())
    }

    public func contentSize() -> CGSize {
        guard let container = rootContainer else { return CGSize(width: 820, height: 760) }
        var w: Int32 = 0, h: Int32 = 0
        hopqt_widget_size(container, &w, &h)
        if w <= 0 || h <= 0 { return CGSize(width: 820, height: 760) }  // before first layout
        return CGSize(width: Double(w), height: Double(h))
    }

    public func setRelayoutHandler(_ handler: @escaping @MainActor () -> Void) {
        relayoutHandler = handler  // invoked by qtResizeCallback on root-container resize
    }

    /// Render a ``ShapeSpec``'s frame-sized shape with QPainter (Qt's native vector API). The shape is
    /// drawn in a `frameWidth`×`frameHeight` box positioned at (`bleedX`, `bleedY`) within the widget, so
    /// transform overflow (which the widget was enlarged to fit) isn't clipped. QPainter's coordinate
    /// space is top-left/y-down, matching HopUI's.
    static func drawShape(_ spec: ShapeSpec, frameWidth: Double, frameHeight: Double,
                          bleedX: Double, bleedY: Double, painter: UnsafeMutableRawPointer) {
        let rect = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        hopqt_painter_save(painter)
        defer { hopqt_painter_restore(painter) }

        // Position the frame within the (possibly enlarged) widget, then apply the center-anchored
        // offset/rotation/scale transform (QPainter rotates in degrees).
        hopqt_painter_translate(painter, bleedX, bleedY)
        let cx = Double(rect.midX), cy = Double(rect.midY)
        hopqt_painter_translate(painter, cx + Double(spec.offset.width), cy + Double(spec.offset.height))
        if spec.rotation.radians != 0 { hopqt_painter_rotate(painter, spec.rotation.degrees) }
        if spec.scaleX != 1 || spec.scaleY != 1 { hopqt_painter_scale(painter, Double(spec.scaleX), Double(spec.scaleY)) }
        hopqt_painter_translate(painter, -cx, -cy)

        guard let qpath = hopqt_path_new() else { return }
        defer { hopqt_path_free(qpath) }
        appendPath(spec.path(rect), to: qpath)

        if let fill = spec.fill {
            hopqt_painter_fill_path(painter, qpath, fill.red, fill.green, fill.blue, fill.opacity)
        }
        if let stroke = spec.stroke {
            hopqt_painter_stroke_path(painter, qpath, stroke.red, stroke.green, stroke.blue, stroke.opacity, Double(spec.lineWidth))
        }
    }

    /// Replay a HopUI ``Path`` into a QPainterPath via the native Qt path primitives.
    private static func appendPath(_ path: Path, to qpath: UnsafeMutableRawPointer) {
        for element in path.elements {
            switch element {
            case .move(let p): hopqt_path_move_to(qpath, Double(p.x), Double(p.y))
            case .line(let p): hopqt_path_line_to(qpath, Double(p.x), Double(p.y))
            case .quadCurve(let p, let c):
                hopqt_path_quad_to(qpath, Double(c.x), Double(c.y), Double(p.x), Double(p.y))
            case .curve(let p, let c1, let c2):
                hopqt_path_cubic_to(qpath, Double(c1.x), Double(c1.y), Double(c2.x), Double(c2.y), Double(p.x), Double(p.y))
            case .closeSubpath: hopqt_path_close(qpath)
            case .rect(let r):
                hopqt_path_add_rect(qpath, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
            case .roundedRect(let r, let cs):
                let rx = min(Double(cs.width), Double(r.width) / 2)
                let ry = min(Double(cs.height), Double(r.height) / 2)
                hopqt_path_add_rounded_rect(qpath, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), rx, ry)
            case .ellipse(let r):
                hopqt_path_add_ellipse(qpath, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
            case .arc(let center, let radius, let start, let end, let clockwise):
                hopqt_path_add_arc(qpath, Double(center.x), Double(center.y), Double(radius),
                                   start.radians, end.radians, clockwise ? 1 : 0)
            }
        }
    }

    public func scheduleOnMainThread(_ work: @escaping @MainActor () -> Void) {
        let thunk = QtMainThunk(work)
        hopqt_post(qtPostCallback, Unmanaged.passRetained(thunk).toOpaque())
    }

    public func setColorScheme(_ colorScheme: ColorScheme?) {
        // nil follows the system; Qt 6.8+ switches via QStyleHints.setColorScheme.
        hopqt_set_color_scheme(colorScheme == .dark ? 1 : 0)
    }

    public func run(title: String, onReady: @escaping @MainActor (QtWidget) -> Void) {
        let app = hopqt_app_new()
        self.app = app
        // Route Swift Concurrency (Task/await on the main actor) onto Qt's event loop. Installed after
        // the QApplication exists, since the enqueue path posts to qApp.
        installQtMainExecutor()
        let window = hopqt_window_new(title)!
        self.window = window
        // Honor HOP_WINDOW_SIZE (uniform screenshot size) for the primary window.
        if let size = hopRequestedWindowSize() { hopqt_widget_resize(window, Int32(size.width), Int32(size.height)) }

        // An absolute-positioning central widget fills the window; the layout engine sizes/positions the
        // mounted root within it, and reports resizes so the runtime can re-lay-out.
        let central = hopqt_fixed_new()!
        hopqt_window_set_central(window, central)
        hopqt_fixed_connect_resize(central, qtResizeCallback, Unmanaged.passUnretained(self).toOpaque())
        rootContainer = central
        let container = QtWidget(central)
        container.isFixed = true
        onReady(container)

        hopqt_window_show(window)
        _ = hopqt_app_exec(app)
    }

    public func openWindow(title: String, onReady: @escaping @MainActor (QtWidget) -> Void) {
        let window = hopqt_window_new(title)!
        // A native box central widget lays out the (static) secondary-window content; the engine isn't
        // run for secondary windows.
        let central = hopqt_vbox_new(8)!
        hopqt_window_set_central(window, central)
        let container = QtWidget(central)  // isFixed = false → native box insert
        onReady(container)
        hopqt_window_show(window)
        secondaryWindows.append(window)
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
        guard signature != menuSignature, let window else { return }
        menuSignature = signature
        menuBoxes = []

        let menubar = hopqt_menu_bar(window)
        for spec in menus {
            let menu = hopqt_menu_add(menubar, spec.title)
            for item in spec.items {
                switch item.kind {
                case .separator:
                    hopqt_menu_add_separator(menu)
                case .button(let title, let action):
                    let box = QtActionBox()
                    box.action = action
                    menuBoxes.append(box)
                    hopqt_menu_add_button(menu, title, qtClickCallback, Unmanaged.passUnretained(box).toOpaque())
                case .command(let title, let command):
                    hopqt_menu_add_command(menu, title, Self.commandCode(command))
                }
            }
        }
    }

    private static func commandCode(_ command: StandardCommand) -> Int32 {
        switch command {
        case .cut: return 0
        case .copy: return 1
        case .paste: return 2
        case .undo: return 3
        case .redo: return 4
        case .selectAll: return 5
        }
    }

    public func setToolbar(_ items: [ToolbarItemSpec]) {
        let signature = items.map { item -> String in
            switch item.kind {
            case .text(let string): return "t:\(string)"
            case .button(let title, _): return "b:\(title)"
            }
        }.joined(separator: "|")
        guard signature != toolbarSignature, let window else { return }
        toolbarSignature = signature

        if toolbar == nil { toolbar = hopqt_toolbar_add(window) }
        guard let toolbar else { return }
        hopqt_toolbar_clear(toolbar)
        toolbarBoxes = []
        for item in items {
            switch item.kind {
            case .text(let string):
                hopqt_toolbar_add_label(toolbar, string)
            case .button(let title, let action):
                let box = QtActionBox()
                box.action = action
                toolbarBoxes.append(box)
                hopqt_toolbar_add_button(toolbar, title, qtClickCallback, Unmanaged.passUnretained(box).toOpaque())
            }
        }
    }
}
