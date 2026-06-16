// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import CGTK4
import HopUI
import Foundation  // Date (for DatePicker value conversion)

/// Opaque handle wrapping a `GtkWidget *` (and, for buttons, its click action box).
public final class GTK4Widget {
    let widget: UnsafeMutableRawPointer
    var actionBox: GTK4ActionBox?
    var isSplit = false
    var isTabView = false
    var isShape = false
    var isToggle = false
    var isImage = false
    var imageResizable = false
    var isProgress = false
    var isScroll = false  // a GtkScrolledWindow (its single child is the scrollable content)
    var flexibleWidth = false  // text fields / sliders / progress bars fill the offered width (SwiftUI-like)
    var scrollHandler: (@MainActor (CGSize) -> Void)?
    var scrollConnected = false
    var pulseTimerId: UInt32 = 0  // GLib source id of the indeterminate-progress pulse timer (0 = none)
    // Action boxes for a drop-down menu's items, retained so their C callbacks stay valid.
    var retainedBoxes: [GTK4ActionBox] = []
    init(_ widget: UnsafeMutableRawPointer) { self.widget = widget }
}

/// Carries a raw GTK pointer across the isolation boundary of a main-thread C callback. GTK
/// guarantees these callbacks run on the main thread, so this crossing is safe.
private struct SendableGTKPointer: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

/// Carries a Cairo context pointer into the main-thread draw closure. GTK calls the draw function on
/// the main thread, so the crossing is safe.
private struct SendableCairo: @unchecked Sendable {
    let cr: OpaquePointer
}

/// Holds a button's Swift action so the C click trampoline can reach it via a `user_data` pointer.
/// The owning ``GTK4Widget`` retains this box, so we pass it unretained across the C boundary.
final class GTK4ActionBox {
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
    /// Picker option labels (for change detection) and whether the drop-down's selection signal is wired.
    var pickerOptions: [String] = []
    var dropdownConnected = false
    /// Date-picker state: the change callback (called with Unix seconds), the GTK composite-box pointer so
    /// the change callback can read the combined value, whether the sub-widget signals are wired, and a
    /// guard suppressing the callback while we reflect the bound value programmatically.
    var onChangeDate: (@MainActor (Double) -> Void)?
    var dateWidget: UnsafeMutableRawPointer?
    var dateConnected = false
    var suppressDate = false
    /// Outline (tree) state: the pre-order flattened rows the C row callbacks read, a structure signature
    /// for rebuild detection, the last reflected selection key, and the key→selection callback.
    var treeFlat: [(key: String, title: String, depth: Int)] = []
    var treeSignature: String?
    var lastSelectedKey: String?
    var onSelectKey: (@MainActor (String?) -> Void)?
    /// Current shape to draw, read by the GtkDrawingArea draw callback (for `.shape` widgets).
    var shape: ShapeSpec?
    /// Layout frame size (from `.frame`) and the transform bleed offset, so the draw callback can paint
    /// the frame-sized shape at the right spot within the (possibly enlarged) drawing area.
    var frameWidth: Double = 0
    var frameHeight: Double = 0
    var bleedX: Double = 0
    var bleedY: Double = 0
}

// Top-level (non-capturing) C callbacks. C function pointers cannot capture, so context is passed
// through the GTK `user_data` argument and recovered via `Unmanaged`.

private let gtk4ActivateCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { app, userData in
    guard let app, let userData else { return }
    let context = Unmanaged<GTK4RunContext>.fromOpaque(userData).takeUnretainedValue()
    let appPointer = SendableGTKPointer(raw: app)

    // GTK invokes `activate` on the main thread, so assert main-actor isolation to build the window.
    MainActor.assumeIsolated {
        let window = hop_window_new(appPointer.raw)!
        context.toolkit.window = window
        hop_window_set_title(window, context.title)
        hop_window_set_default_size(window, 820, 760)

        // An absolute-positioning GtkFixed fills the window; the layout engine sizes/positions the
        // mounted root within it.
        let container = hop_fixed_new()!
        hop_window_set_child(window, container)
        context.toolkit.rootContainer = container

        // Re-run layout whenever the window resizes.
        let toolkitPtr = Unmanaged.passUnretained(context.toolkit).toOpaque()
        hop_window_connect_resize(window, gtk4ResizeCallback, toolkitPtr)

        context.onReady(GTK4Widget(container))
        hop_window_present(window)
    }
}

private let gtk4ClickedCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.action?() }
}

private let gtk4ChangedCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { entry, userData in
    guard let entry, let userData, let cText = hop_editable_get_text(entry) else { return }
    let text = String(cString: cText)
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onChange?(text) }
}

private let gtk4ValueChangedCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { scale, userData in
    guard let scale, let userData else { return }
    let value = hop_scale_get_value(scale)
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onChangeDouble?(value) }
}

// Fired by the composite date picker's calendar / hour / minute sub-widgets. The emitting sub-widget is
// ignored; the combined value is read from the stored box widget pointer.
private let gtk4DateChangedCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        guard !box.suppressDate, let widget = box.dateWidget else { return }
        box.onChangeDate?(hop_datepicker_get(widget))
    }
}

// GSimpleAction "activate" signature is (action, parameter, user_data).
private let gtk4ActionCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.action?() }
}

// Returns a malloc'd C string for the given row; the GTK shim frees it after copying.
private let gtk4RowCallback: @convention(c) (UInt32, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? = { position, userData in
    guard let userData else { return nil }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    let text = MainActor.assumeIsolated { box.rowText?(Int(position)) ?? "" }
    return strdup(text)
}

private let gtk4ListSelectionCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { model, _, userData in
    guard let model, let userData else { return }
    let raw = hop_selection_model_get_selected(model)
    let index: Int? = (raw == hop_list_invalid()) ? nil : Int(raw)
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if box.lastSelected != index {
            box.lastSelected = index
            box.onSelect?(index)
        }
    }
}

// GtkSwitch notify::active: report the new on/off state for a Toggle. user_data is the action box.
private let gtk4SwitchCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { sw, _, userData in
    guard let sw, let userData else { return }
    let on = hop_switch_get_active(sw) != 0
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if box.lastBool != on {
            box.lastBool = on
            box.onChangeBool?(on)
        }
    }
}

// GtkNotebook switch-page: report the newly-selected tab index. user_data is the tab-view handle.
private let gtk4SwitchPageCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void = { _, _, pageNum, userData in
    guard let userData else { return }
    let index = Int(pageNum)
    let handle = Unmanaged<GTK4Widget>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        guard let box = handle.actionBox else { return }
        if box.lastTab != index {
            box.lastTab = index
            box.onSelectTab?(index)
        }
    }
}

// Outline row callbacks: return the title / key (malloc'd; the shim frees) and depth for a flattened row.
private let gtk4TreeTitleCallback: @convention(c) (UInt32, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? = { position, userData in
    guard let userData else { return nil }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    let title = MainActor.assumeIsolated { box.treeFlat.indices.contains(Int(position)) ? box.treeFlat[Int(position)].title : "" }
    return strdup(title)
}
private let gtk4TreeKeyCallback: @convention(c) (UInt32, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? = { position, userData in
    guard let userData else { return nil }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    let key = MainActor.assumeIsolated { box.treeFlat.indices.contains(Int(position)) ? box.treeFlat[Int(position)].key : "" }
    return strdup(key)
}
private let gtk4TreeDepthCallback: @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Int32 = { position, userData in
    guard let userData else { return 0 }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated { Int32(box.treeFlat.indices.contains(Int(position)) ? box.treeFlat[Int(position)].depth : 0) }
}

// Tree selection (notify::selected): read the selected row's key and report it. user_data is the handle.
private let gtk4TreeSelectionCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, userData in
    guard let userData else { return }
    let handle = Unmanaged<GTK4Widget>.fromOpaque(userData).takeUnretainedValue()
    let key: String? = hop_tree_get_selected_key(handle.widget).map { let s = String(cString: $0); free($0); return s }
    MainActor.assumeIsolated {
        guard let box = handle.actionBox else { return }
        if box.lastSelectedKey != key {
            box.lastSelectedKey = key
            box.onSelectKey?(key)
        }
    }
}

// Repeating timer callback that animates an indeterminate progress bar. G_SOURCE_CONTINUE keeps it going.
private let gtk4PulseCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { widget in
    guard let widget else { return 0 }
    hop_progress_pulse(widget)
    return 1  // G_SOURCE_CONTINUE
}

// GtkDropDown selection callback (notify::selected): reports the newly-selected index for a Picker.
private let gtk4DropDownCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { dropdown, _, userData in
    guard let dropdown, let userData else { return }
    let raw = hop_dropdown_get_selected(dropdown)
    let index: Int? = (raw == hop_list_invalid()) ? nil : Int(raw)
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if box.lastSelected != index {
            box.lastSelected = index
            if let index { box.onSelect?(index) }
        }
    }
}

// GtkDrawingArea draw callback: (area, cairo_t, width, height, user_data). Recovers the shape spec
// from the action box and paints it with Cairo on the main thread.
private let gtk4DrawCallback: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Void = { _, cr, width, height, userData in
    guard let cr, let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    let wrapped = SendableCairo(cr: cr)
    MainActor.assumeIsolated {
        guard let spec = box.shape else { return }
        // Fall back to the allocated size when no explicit frame was given.
        let frameW = box.frameWidth > 0 ? box.frameWidth : Double(width)
        let frameH = box.frameHeight > 0 ? box.frameHeight : Double(height)
        GTK4Toolkit.drawShape(spec, frameWidth: frameW, frameHeight: frameH,
                              bleedX: box.bleedX, bleedY: box.bleedY, cr: wrapped.cr)
    }
}

// Window resize (notify::default-width/height): re-run the layout engine. user_data is the toolkit.
private let gtk4ResizeCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, userData in
    guard let userData else { return }
    let toolkit = Unmanaged<GTK4Toolkit>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { toolkit.relayoutHandler?() }
}

// Scrolled-window adjustment "value-changed": report the new offset so virtualized content re-materializes.
// user_data is the scroll GTK4Widget handle.
private let gtk4ScrollCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, userData in
    guard let userData else { return }
    let handle = Unmanaged<GTK4Widget>.fromOpaque(userData).takeUnretainedValue()
    var x = 0.0, y = 0.0
    hop_scrolled_window_get_offset(handle.widget, &x, &y)
    MainActor.assumeIsolated { handle.scrollHandler?(CGSize(width: x, height: y)) }
}

/// Holds a one-shot main-thread closure for the GLib idle callback to invoke.
final class GTK4MainThunk {
    let work: @MainActor () -> Void
    init(_ work: @escaping @MainActor () -> Void) { self.work = work }
}

private let gtk4IdleCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { userData in
    guard let userData else { return 0 }
    let thunk = Unmanaged<GTK4MainThunk>.fromOpaque(userData).takeRetainedValue()
    MainActor.assumeIsolated { thunk.work() }
    return 0  // G_SOURCE_REMOVE — run once
}

/// Carries the app's title and mount callback into the GTK `activate` signal.
final class GTK4RunContext {
    let toolkit: GTK4Toolkit
    let title: String
    let onReady: @MainActor (GTK4Widget) -> Void
    init(toolkit: GTK4Toolkit, title: String, onReady: @escaping @MainActor (GTK4Widget) -> Void) {
        self.toolkit = toolkit
        self.title = title
        self.onReady = onReady
    }
}

/// GTK4 toolkit: maps HopUI widgets onto GtkBox / GtkLabel / GtkButton and runs the GtkApplication
/// main loop. Works on macOS, Linux, and Windows wherever GTK4 is installed (the MVP lets GtkBox
/// perform layout; the geometry-owning layout engine is a later phase).
public final class GTK4Toolkit: AppToolkit {
    public typealias Handle = GTK4Widget

    private var app: UnsafeMutableRawPointer?
    var window: UnsafeMutableRawPointer?
    private var headerBar: UnsafeMutableRawPointer?
    private var toolbarBoxes: [GTK4ActionBox] = []
    private var toolbarSignature: String?
    private var menuBoxes: [GTK4ActionBox] = []
    private var menuSignature: String?
    // Secondary windows (e.g. About) are kept here for the app's lifetime.
    private var secondaryWindows: [UnsafeMutableRawPointer] = []
    // The root GtkFixed filling the window's content; its allocated size is the layout root proposal.
    var rootContainer: UnsafeMutableRawPointer?
    // Called by the runtime to re-run the layout engine when the window content size changes.
    var relayoutHandler: (@MainActor () -> Void)?

    public init() {}

    public func makeWidget(_ kind: WidgetKind) -> GTK4Widget {
        let widget: UnsafeMutableRawPointer
        switch kind {
        // Box-model containers are absolute-positioning GtkFixed layers; the layout engine owns geometry.
        case .vstack, .hstack, .zstack, .spacer, .window, .geometry, .lazyStack: widget = hop_fixed_new()!
        case .groupBox:
            widget = hop_fixed_new()!
            hop_widget_add_css_class(widget, "card")  // Adwaita's rounded, bordered, filled card chrome
        case .scroll: widget = hop_scrolled_window_new()!  // a real clipping/scrolling viewport
        case .label:  widget = hop_label_new("")!
        case .button: widget = hop_button_new("")!
        case .textField: widget = hop_entry_new()!
        case .slider: widget = hop_scale_new(0, 1)!
        case .list: widget = hop_list_new()!
        case .sidebarList:
            widget = hop_list_new()!
            hop_list_set_sidebar(widget, 1)  // source-list styling baked in at creation
        case .outline: widget = hop_tree_new()!
        case .sidebarOutline:
            widget = hop_tree_new()!
            hop_tree_set_sidebar(widget, 1)  // source-list styling baked in at creation
        case .splitView: widget = hop_paned_new()!
        case .tabView: widget = hop_notebook_new()!
        case .image: widget = hop_picture_new()!
        case .toggle: widget = hop_switch_new()!
        case .secureField:
            widget = hop_entry_new()!
            hop_entry_set_visibility(widget, 0)  // mask typed characters (password field)
        case .shape: widget = hop_drawing_area_new()!
        case .menu: widget = hop_menu_button_new()!
        case .picker: widget = hop_dropdown_new()!
        case .datePicker: widget = hop_datepicker_new()!
        case .progress: widget = hop_progress_bar_new()!
        case .separator:
            widget = hop_separator_new(1)!  // a divider between stacked rows is a horizontal line
        }
        // Take an owning reference so our handle stays valid across reparenting/removal.
        hop_object_ref_sink(widget)
        let handle = GTK4Widget(widget)
        if kind == .textField || kind == .secureField || kind == .slider || kind == .progress { handle.flexibleWidth = true }

        if kind == .button {
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_connect_clicked(widget, gtk4ClickedCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if kind == .textField || kind == .secureField {
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_connect_changed(widget, gtk4ChangedCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if kind == .toggle {
            handle.isToggle = true
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_switch_connect(widget, gtk4SwitchCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if kind == .slider {
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_connect_value_changed(widget, gtk4ValueChangedCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if kind == .list || kind == .sidebarList {
            // The selection signal is connected in configureList, after the model is built.
            handle.actionBox = GTK4ActionBox()
        } else if kind == .outline || kind == .sidebarOutline {
            // The selection signal is connected in configureOutline, after the tree model is built.
            handle.actionBox = GTK4ActionBox()
        } else if kind == .shape {
            handle.isShape = true
            let box = GTK4ActionBox()
            handle.actionBox = box
            hop_drawing_area_set_draw_func(widget, gtk4DrawCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if kind == .image {
            handle.isImage = true
        } else if kind == .picker {
            // Selection signal is connected in configurePicker after the model is set.
            handle.actionBox = GTK4ActionBox()
        } else if kind == .datePicker {
            // Sub-widget signals are connected in configureDatePicker (once components are known).
            handle.actionBox = GTK4ActionBox()
        } else if kind == .progress {
            handle.isProgress = true
        } else if kind == .splitView {
            handle.isSplit = true
        } else if kind == .tabView {
            handle.isTabView = true
            handle.actionBox = GTK4ActionBox()  // switch-page signal connected in configureTabs
        } else if kind == .scroll {
            handle.isScroll = true
        }
        return handle
    }

    public func configure(_ handle: GTK4Widget, _ patch: WidgetPatch) {
        if let text = patch.text { hop_label_set_text(handle.widget, text) }
        if let title = patch.title { hop_button_set_label(handle.widget, title) }
        if let placeholder = patch.placeholder { hop_entry_set_placeholder(handle.widget, placeholder) }
        if let value = patch.value {
            // Guard against resetting the text (and the cursor) to what's already shown, which also
            // prevents a feedback loop when our own edit triggers a re-render.
            let current = hop_editable_get_text(handle.widget).map { String(cString: $0) } ?? ""
            if current != value { hop_editable_set_text(handle.widget, value) }
        }
        if let minV = patch.minValue, let maxV = patch.maxValue {
            hop_scale_set_range(handle.widget, minV, maxV)
        }
        if let v = patch.doubleValue {
            // Guard prevents a feedback loop when our own drag triggers a re-render.
            if abs(hop_scale_get_value(handle.widget) - v) > 0.0001 { hop_scale_set_value(handle.widget, v) }
        }
        if handle.isToggle, let on = patch.boolValue {
            // Guard against re-setting (and re-firing notify::active) the state we already show.
            if (hop_switch_get_active(handle.widget) != 0) != on {
                handle.actionBox?.lastBool = on
                hop_switch_set_active(handle.widget, on ? 1 : 0)
            }
        }
        if let css = Self.cssStyle(patch) { hop_widget_set_css(handle.widget, css) }

        // Progress bar: a fraction is determinate; nil pulses an indeterminate bar via a repeating timer.
        if handle.isProgress {
            if let value = patch.progressValue {
                if handle.pulseTimerId != 0 { hop_source_remove(handle.pulseTimerId); handle.pulseTimerId = 0 }
                hop_progress_set_fraction(handle.widget, value)
            } else if handle.pulseTimerId == 0 {
                hop_progress_set_fraction(handle.widget, 0)
                handle.pulseTimerId = hop_timeout_add_id(120, gtk4PulseCallback, handle.widget)
            }
        }

        // Accessibility → GtkAccessible properties/state (read by AT-SPI / Orca).
        if let label = patch.accessibilityLabel { hop_a11y_label(handle.widget, label) }
        // GTK has a single description slot; prefer an explicit hint, else fall back to the value.
        if let description = patch.accessibilityHint ?? patch.accessibilityValue {
            hop_a11y_description(handle.widget, description)
        }
        if let hidden = patch.accessibilityHidden { hop_a11y_hidden(handle.widget, hidden ? 1 : 0) }
    }

    /// Builds an inline CSS rule (wrapped in `* { }` for the widget node) for the patch's styling.
    private static func cssStyle(_ patch: WidgetPatch) -> String? {
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
        return "* { " + rules.joined(separator: "; ") + "; }"
    }

    public func insert(_ child: GTK4Widget, into parent: GTK4Widget, at index: Int) {
        if parent.isScroll {
            hop_scrolled_window_set_child(parent.widget, child.widget)  // the single scrollable content
            return
        }
        if parent.isSplit {
            if index == 0 {
                hop_paned_set_start(parent.widget, child.widget)
            } else {
                hop_paned_set_end(parent.widget, child.widget)
                hop_paned_set_position(parent.widget, 260)
            }
            return
        }
        if parent.isTabView {
            hop_notebook_insert(parent.widget, child.widget, "", Int32(index))  // titles set in configureTabs
            return
        }
        if hop_is_fixed(parent.widget) != 0 {
            // Absolute container: the engine repositions via setFrame; subview add order is z-order.
            hop_fixed_put(parent.widget, child.widget)
        } else {
            // A native box (e.g. a secondary window's content): append + reorder to honor the index.
            hop_box_append(parent.widget, child.widget)
            hop_box_reorder(parent.widget, child.widget, Int32(index))
        }
    }

    public func move(_ child: GTK4Widget, in parent: GTK4Widget, to index: Int) {
        guard !parent.isSplit, !parent.isTabView else { return }  // pages don't reorder in the MVP
        // GtkFixed has no child reorder; z-order rarely matters for non-overlapping layouts, and the
        // engine repositions every child each pass, so a fixed-parent move is a no-op in the MVP.
        if hop_is_fixed(parent.widget) == 0 {
            hop_box_reorder(parent.widget, child.widget, Int32(index))
        }
    }

    public func remove(_ child: GTK4Widget, from parent: GTK4Widget) {
        if parent.isSplit {
            // Detaching a pane child: handled by GTK when the paned is torn down; nothing to do here.
        } else if parent.isTabView {
            hop_notebook_remove(parent.widget, child.widget)
        } else if hop_is_fixed(parent.widget) != 0 {
            hop_fixed_remove(parent.widget, child.widget)
        } else {
            hop_box_remove(parent.widget, child.widget)
        }
        hop_object_unref(child.widget)
    }

    public func setAction(_ handle: GTK4Widget, _ action: (@MainActor () -> Void)?) {
        handle.actionBox?.action = action
    }

    public func setTextHandler(_ handle: GTK4Widget, _ handler: (@MainActor (String) -> Void)?) {
        handle.actionBox?.onChange = handler
    }

    public func setValueHandler(_ handle: GTK4Widget, _ handler: (@MainActor (Double) -> Void)?) {
        handle.actionBox?.onChangeDouble = handler
    }

    public func setBoolHandler(_ handle: GTK4Widget, _ handler: (@MainActor (Bool) -> Void)?) {
        handle.actionBox?.onChangeBool = handler
    }

    public func configureList(_ handle: GTK4Widget, _ spec: ListSpec) {
        guard let box = handle.actionBox else { return }
        box.rowText = spec.rowText
        box.onSelect = spec.onSelect
        if box.listCount != spec.count {
            box.listCount = spec.count
            let boxPtr = Unmanaged.passUnretained(box).toOpaque()
            hop_list_set_strings(handle.widget, UInt32(spec.count), gtk4RowCallback, boxPtr)
            _ = hop_list_connect_selection(handle.widget, gtk4ListSelectionCallback, boxPtr)
        }
        let target = spec.selectedIndex
        let raw = hop_list_get_selected(handle.widget)
        let current: Int? = (raw == hop_list_invalid()) ? nil : Int(raw)
        if current != target {
            box.lastSelected = target
            hop_list_set_selected(handle.widget, target.map { UInt32($0) } ?? hop_list_invalid())
        }
    }

    public func configureOutline(_ handle: GTK4Widget, _ spec: OutlineSpec) {
        guard let box = handle.actionBox else { return }
        let flat = spec.flattened()
        // The toolkits only carry string keys natively, so map each key back to its original AnyHashable
        // id to preserve the binding's selection type (the List does `id.base as? SelectionValue`).
        let idByKey = Dictionary(flat.map { ($0.node.key, $0.node.id) }, uniquingKeysWith: { first, _ in first })
        box.onSelectKey = { key in spec.onSelect(key.flatMap { idByKey[$0] }) }

        // Rebuild the native tree only when the structure changes (not on every reconcile, which would
        // collapse expansion and re-trigger selection); the model + selection signal are recreated here.
        let signature = spec.structureSignature
        if box.treeSignature != signature {
            box.treeSignature = signature
            box.treeFlat = flat.map { (key: $0.node.key, title: $0.node.title, depth: $0.depth) }
            let boxPtr = Unmanaged.passUnretained(box).toOpaque()
            hop_tree_set_rows(handle.widget, UInt32(flat.count),
                              gtk4TreeTitleCallback, gtk4TreeKeyCallback, gtk4TreeDepthCallback, boxPtr)
            _ = hop_tree_connect_selection(handle.widget, gtk4TreeSelectionCallback,
                                           Unmanaged.passUnretained(handle).toOpaque())
        }

        // Reflect the bound selection.
        let targetKey = spec.selectedID.map { "\($0.base)" }
        let currentKey = hop_tree_get_selected_key(handle.widget).map { p -> String in
            let s = String(cString: p); free(p); return s
        }
        if currentKey != targetKey {
            box.lastSelectedKey = targetKey
            if let targetKey { hop_tree_select_key(handle.widget, targetKey) }
            else { hop_tree_select_key(handle.widget, nil) }
        }
    }

    public func configureMenu(_ handle: GTK4Widget, _ menu: MenuContent) {
        hop_menu_button_set_label(handle.widget, menu.label)
        // A fresh per-widget action group (replaces any previous one with the same prefix), plus a GMenu
        // model referencing "menu.btnN" detailed actions.
        let group = hop_simple_action_group_new()!
        var boxes: [GTK4ActionBox] = []
        var counter = 0
        let model = buildGMenu(menu.entries, group: group, boxes: &boxes, counter: &counter)
        hop_widget_insert_action_group(handle.widget, "menu", group)
        hop_object_unref(group)
        hop_menu_button_set_menu_model(handle.widget, model)
        hop_object_unref(model)
        handle.retainedBoxes = boxes
    }

    /// Build a GMenu from entries, registering each button's action on `group`. Separators split the
    /// entries into GMenu sections. Returns an owned GMenu ref (caller unrefs after setting the model).
    private func buildGMenu(_ entries: [MenuEntry], group: UnsafeMutableRawPointer,
                            boxes: inout [GTK4ActionBox], counter: inout Int) -> UnsafeMutableRawPointer {
        let menu = hop_menu_new()!
        var section = hop_menu_new()!
        var sectionHasItems = false
        func flushSection() {
            guard sectionHasItems else { return }
            hop_menu_append_section(menu, section)
            hop_object_unref(section)
            section = hop_menu_new()!
            sectionHasItems = false
        }
        for entry in entries {
            switch entry {
            case .separator:
                flushSection()
            case .button(let title, let action):
                let name = "btn\(counter)"
                counter += 1
                let gaction = hop_simple_action_new(name)!
                let box = GTK4ActionBox()
                box.action = action
                boxes.append(box)
                _ = hop_action_connect_activate(gaction, gtk4ActionCallback, Unmanaged.passUnretained(box).toOpaque())
                hop_action_group_add_action(group, gaction)
                hop_object_unref(gaction)
                hop_menu_append_item(section, title, "menu.\(name)")
                sectionHasItems = true
            case .submenu(let title, let subEntries):
                let submenu = buildGMenu(subEntries, group: group, boxes: &boxes, counter: &counter)
                hop_menu_append_submenu(section, title, submenu)
                hop_object_unref(submenu)
                sectionHasItems = true
            }
        }
        flushSection()
        hop_object_unref(section)  // the trailing, unappended section
        return menu
    }

    public func configurePicker(_ handle: GTK4Widget, _ spec: PickerSpec) {
        guard let box = handle.actionBox else { return }
        box.onSelect = { if let index = $0 { spec.onSelect(index) } }
        if box.pickerOptions != spec.options {
            box.pickerOptions = spec.options
            box.rowText = { spec.options[$0] }
            let boxPtr = Unmanaged.passUnretained(box).toOpaque()
            hop_dropdown_set_strings(handle.widget, UInt32(spec.options.count), gtk4RowCallback, boxPtr)
            if !box.dropdownConnected {
                _ = hop_dropdown_connect_selection(handle.widget, gtk4DropDownCallback, boxPtr)
                box.dropdownConnected = true
            }
        }
        let target = spec.selectedIndex
        let raw = hop_dropdown_get_selected(handle.widget)
        let current: Int? = (raw == hop_list_invalid()) ? nil : Int(raw)
        if current != target {
            box.lastSelected = target
            hop_dropdown_set_selected(handle.widget, target.map { UInt32($0) } ?? hop_list_invalid())
        }
    }

    public func configureDatePicker(_ handle: GTK4Widget, _ spec: DatePickerSpec) {
        guard let box = handle.actionBox else { return }
        box.onChangeDate = { spec.onChange(Date(timeIntervalSince1970: $0)) }
        box.dateWidget = handle.widget
        let wantDate = spec.components.contains(.date)
        let wantTime = spec.components.contains(.hourAndMinute)
        // GTK has no compact date field, so style is moot: always the inline calendar + spin composite.
        hop_datepicker_set_components(handle.widget, wantDate ? 1 : 0, wantTime ? 1 : 0)
        if !box.dateConnected {
            hop_datepicker_connect(handle.widget, gtk4DateChangedCallback, Unmanaged.passUnretained(box).toOpaque())
            box.dateConnected = true
        }
        // Reflect the bound value without re-firing the handler (the calendar/spin emit on programmatic set).
        let target = spec.date.timeIntervalSince1970
        if abs(hop_datepicker_get(handle.widget) - target) > 0.5 {
            box.suppressDate = true
            hop_datepicker_set(handle.widget, target)
            box.suppressDate = false
        }
    }

    public func configureShape(_ handle: GTK4Widget, _ spec: ShapeSpec) {
        guard let box = handle.actionBox else { return }
        box.shape = spec
        // Sizing/positioning (including transform-bleed enlargement) is applied in setFrame, once the
        // layout engine has chosen the shape's frame.
        hop_widget_queue_draw(handle.widget)
    }

    public func configureTabs(_ handle: GTK4Widget, _ spec: TabSpec) {
        guard let box = handle.actionBox else { return }
        box.onSelectTab = spec.onSelect
        for (index, title) in spec.titles.enumerated() {
            hop_notebook_set_tab_label_index(handle.widget, Int32(index), title)
        }
        if !box.tabConnected {
            box.tabConnected = true
            _ = hop_notebook_connect_switch(handle.widget, gtk4SwitchPageCallback,
                                            Unmanaged.passUnretained(handle).toOpaque())
        }
        let current = Int(hop_notebook_get_current(handle.widget))
        if current != spec.selectedIndex {
            box.lastTab = spec.selectedIndex
            hop_notebook_set_current(handle.widget, Int32(spec.selectedIndex))
        }
    }

    public func configureImage(_ handle: GTK4Widget, _ spec: ImageSpec) {
        handle.imageResizable = spec.resizable
        switch spec.source {
        case .system(let name):
            hop_picture_set_icon(handle.widget, name, 64)  // no SF Symbols on GTK → icon theme + fallback
        case .named, .file:
            if let url = spec.resolvedURL() { hop_picture_set_file(handle.widget, url.path) }
        case .data(let data):
            data.withUnsafeBytes { raw in
                hop_picture_set_bytes(handle.widget, raw.bindMemory(to: UInt8.self).baseAddress, Int32(data.count))
            }
        }
        // 0=FILL(stretch) 1=CONTAIN(fit) 2=COVER(fill); a non-resizable image sits 1:1 in its natural frame.
        let fit: Int32
        if !spec.resizable {
            fit = 1
        } else {
            switch spec.contentMode {
            case .none: fit = 0
            case .fit:  fit = 1
            case .fill: fit = 2
            }
        }
        hop_picture_set_content_fit(handle.widget, fit)
    }

    // MARK: - Framework-owned layout

    public func setFrame(_ handle: GTK4Widget, _ rect: CGRect) {
        if handle.isShape, let box = handle.actionBox {
            // A GtkDrawingArea clips to its size, so enlarge it to fit any transform overflow and offset
            // the drawing-area origin by the bleed so the frame-sized shape still lands at (minX, minY).
            box.frameWidth = Double(rect.width)
            box.frameHeight = Double(rect.height)
            let bleed = box.shape.map { $0.transformBleed(width: rect.width, height: rect.height) }
            let left = Double(bleed?.left ?? 0), top = Double(bleed?.top ?? 0)
            let right = Double(bleed?.right ?? 0), bottom = Double(bleed?.bottom ?? 0)
            box.bleedX = left
            box.bleedY = top
            let paddedW = Double(rect.width) + left + right
            let paddedH = Double(rect.height) + top + bottom
            hop_widget_set_frame(handle.widget,
                                 Int32((Double(rect.minX) - left).rounded()),
                                 Int32((Double(rect.minY) - top).rounded()),
                                 Int32(paddedW.rounded(.up)), Int32(paddedH.rounded(.up)))
            hop_widget_queue_draw(handle.widget)
        } else {
            hop_widget_set_frame(handle.widget,
                                 Int32(Double(rect.minX).rounded()), Int32(Double(rect.minY).rounded()),
                                 Int32(Double(rect.width).rounded()), Int32(Double(rect.height).rounded()))
        }
    }

    public func measure(_ handle: GTK4Widget, _ proposal: ProposedViewSize) -> CGSize {
        // Shapes are greedy: they fill whatever they're offered (default 100×100 when unspecified).
        if handle.isShape { return proposal.resolved(CGSize(width: 100, height: 100)) }
        // Images: natural pixel size from the paintable, greedy when `.resizable()`.
        if handle.isImage {
            var iw: Int32 = 0, ih: Int32 = 0
            hop_picture_natural_size(handle.widget, &iw, &ih)
            let natural = CGSize(width: Double(iw), height: Double(ih))
            return handle.imageResizable ? proposal.resolved(natural) : natural
        }
        var w: Int32 = 0, h: Int32 = 0
        hop_widget_measure(handle.widget, -1, &w, &h)  // natural/intrinsic size
        // Flexible-width controls (text fields, sliders, progress bars) expand to the offered width.
        if handle.flexibleWidth, let pw = proposal.width, pw.isFinite {
            return CGSize(width: Swift.max(pw, Double(w)), height: Double(h))
        }
        return CGSize(width: Double(w), height: Double(h))
    }

    public func sizeOf(_ handle: GTK4Widget) -> CGSize {
        var w: Int32 = 0, h: Int32 = 0
        hop_widget_get_size(handle.widget, &w, &h)
        return CGSize(width: Double(w), height: Double(h))
    }

    public func setScrollHandler(_ handle: GTK4Widget, _ handler: (@MainActor (CGSize) -> Void)?) {
        handle.scrollHandler = handler
        // Connect the scrolled window's adjustments once, so user scrolls drive virtualized re-materialization.
        if handle.isScroll, !handle.scrollConnected, handler != nil {
            hop_scrolled_window_connect_scroll(handle.widget, gtk4ScrollCallback, Unmanaged.passUnretained(handle).toOpaque())
            handle.scrollConnected = true
        }
    }

    public func contentSize() -> CGSize {
        guard let container = rootContainer else { return CGSize(width: 820, height: 760) }
        var w: Int32 = 0, h: Int32 = 0
        hop_widget_get_size(container, &w, &h)
        if w <= 0 || h <= 0 { return CGSize(width: 820, height: 760) }  // before first allocation
        return CGSize(width: Double(w), height: Double(h))
    }

    public func setRelayoutHandler(_ handler: @escaping @MainActor () -> Void) {
        relayoutHandler = handler  // invoked by gtk4ResizeCallback on window resize
    }

    /// Render a ``ShapeSpec``'s frame-sized shape with Cairo (the native GTK4 vector API). The shape is
    /// drawn in a `frameWidth`×`frameHeight` box positioned at (`bleedX`, `bleedY`) within the drawing
    /// area, so transform overflow (which the area was enlarged to fit) isn't clipped. Cairo is already
    /// top-left/y-down, matching HopUI's coordinate space.
    static func drawShape(_ spec: ShapeSpec, frameWidth: Double, frameHeight: Double,
                          bleedX: Double, bleedY: Double, cr: OpaquePointer) {
        let rect = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        cairo_save(cr)
        defer { cairo_restore(cr) }

        // Position the frame within the (possibly enlarged) drawing area, then apply the
        // center-anchored offset/rotation/scale transform.
        cairo_translate(cr, bleedX, bleedY)
        let cx = Double(rect.midX), cy = Double(rect.midY)
        cairo_translate(cr, cx + Double(spec.offset.width), cy + Double(spec.offset.height))
        if spec.rotation.radians != 0 { cairo_rotate(cr, spec.rotation.radians) }
        if spec.scaleX != 1 || spec.scaleY != 1 { cairo_scale(cr, Double(spec.scaleX), Double(spec.scaleY)) }
        cairo_translate(cr, -cx, -cy)

        cairo_new_path(cr)
        appendPath(spec.path(rect), to: cr)

        if let fill = spec.fill {
            cairo_set_source_rgba(cr, fill.red, fill.green, fill.blue, fill.opacity)
            if spec.stroke != nil { cairo_fill_preserve(cr) } else { cairo_fill(cr) }
        }
        if let stroke = spec.stroke {
            cairo_set_source_rgba(cr, stroke.red, stroke.green, stroke.blue, stroke.opacity)
            cairo_set_line_width(cr, Double(spec.lineWidth))
            cairo_stroke(cr)
        }
    }

    /// Replay a HopUI ``Path`` into the current Cairo path. Rects/ellipses/rounded-rects/arcs are
    /// emitted with Cairo's native primitives; quadratic curves are promoted to cubic Béziers.
    private static func appendPath(_ path: Path, to cr: OpaquePointer) {
        var last = CGPoint.zero
        for element in path.elements {
            switch element {
            case .move(let p):
                cairo_move_to(cr, Double(p.x), Double(p.y)); last = p
            case .line(let p):
                cairo_line_to(cr, Double(p.x), Double(p.y)); last = p
            case .quadCurve(let p, let c):
                // Quadratic → cubic: C1 = P0 + 2/3·(C−P0), C2 = P1 + 2/3·(C−P1).
                let c1x = last.x + (c.x - last.x) * 2 / 3, c1y = last.y + (c.y - last.y) * 2 / 3
                let c2x = p.x + (c.x - p.x) * 2 / 3, c2y = p.y + (c.y - p.y) * 2 / 3
                cairo_curve_to(cr, Double(c1x), Double(c1y), Double(c2x), Double(c2y), Double(p.x), Double(p.y))
                last = p
            case .curve(let p, let c1, let c2):
                cairo_curve_to(cr, Double(c1.x), Double(c1.y), Double(c2.x), Double(c2.y), Double(p.x), Double(p.y))
                last = p
            case .closeSubpath:
                cairo_close_path(cr)
            case .rect(let r):
                cairo_rectangle(cr, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
            case .roundedRect(let r, let cs):
                appendRoundedRect(r, cornerSize: cs, to: cr)
            case .ellipse(let r):
                appendEllipse(r, to: cr)
            case .arc(let center, let radius, let start, let end, let clockwise):
                if clockwise {
                    cairo_arc(cr, Double(center.x), Double(center.y), Double(radius), start.radians, end.radians)
                } else {
                    cairo_arc_negative(cr, Double(center.x), Double(center.y), Double(radius), start.radians, end.radians)
                }
                last = center
            }
        }
    }

    /// Cairo has no ellipse primitive: unit-circle arc under a translate+scale (the canonical idiom).
    private static func appendEllipse(_ rect: CGRect, to cr: OpaquePointer) {
        guard rect.width > 0, rect.height > 0 else { return }
        cairo_save(cr)
        cairo_translate(cr, Double(rect.midX), Double(rect.midY))
        cairo_scale(cr, Double(rect.width) / 2, Double(rect.height) / 2)
        cairo_new_sub_path(cr)
        cairo_arc(cr, 0, 0, 1, 0, 2 * Double.pi)
        cairo_restore(cr)
    }

    /// Cairo rounded rectangle: four quarter-circle corner arcs joined into a closed path.
    private static func appendRoundedRect(_ rect: CGRect, cornerSize cs: CGSize, to cr: OpaquePointer) {
        let x = Double(rect.minX), y = Double(rect.minY), w = Double(rect.width), h = Double(rect.height)
        let r = min(Double(cs.width), Double(cs.height), w / 2, h / 2)
        guard r > 0 else { cairo_rectangle(cr, x, y, w, h); return }
        let halfPi = Double.pi / 2
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + r,     y + r,     r, Double.pi, 3 * halfPi)  // top-left
        cairo_arc(cr, x + w - r, y + r,     r, 3 * halfPi, 2 * Double.pi)  // top-right
        cairo_arc(cr, x + w - r, y + h - r, r, 0, halfPi)  // bottom-right
        cairo_arc(cr, x + r,     y + h - r, r, halfPi, Double.pi)  // bottom-left
        cairo_close_path(cr)
    }

    public func run(title: String, onReady: @escaping @MainActor (GTK4Widget) -> Void) {
        // Route Swift Concurrency (Task/await on the main actor) onto GLib's loop before it starts.
        installGTK4MainExecutor()
        let app = hop_app_new("dev.skip.hopui.demo")!
        self.app = app
        let context = GTK4RunContext(toolkit: self, title: title, onReady: onReady)
        _ = hop_connect_activate(app, gtk4ActivateCallback, Unmanaged.passRetained(context).toOpaque())
        _ = hop_app_run(app)
    }

    public func scheduleOnMainThread(_ work: @escaping @MainActor () -> Void) {
        let thunk = GTK4MainThunk(work)
        hop_idle_add(gtk4IdleCallback, Unmanaged.passRetained(thunk).toOpaque())
    }

    public func setColorScheme(_ colorScheme: ColorScheme?) {
        // nil follows the system; GTK4's switch is the application's prefer-dark-theme setting.
        hop_set_prefer_dark(colorScheme == .dark ? 1 : 0)
    }

    public func openWindow(title: String, onReady: @escaping @MainActor (GTK4Widget) -> Void) {
        guard let app else { return }
        let window = hop_window_new(app)!
        hop_window_set_title(window, title)
        hop_window_set_default_size(window, 420, 240)

        // A padded vertical container holds the window's mounted content.
        let container = hop_box_new(0, 8)!
        hop_widget_set_margins(container, 24)
        hop_window_set_child(window, container)

        onReady(GTK4Widget(container))
        hop_window_present(window)
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
        guard signature != menuSignature, let app, let window else { return }
        menuSignature = signature
        menuBoxes = []

        let topMenu = hop_menu_new()!
        var actionIndex = 0
        for spec in menus {
            let submenu = hop_menu_new()!
            var section = hop_menu_new()!
            for item in spec.items {
                switch item.kind {
                case .separator:
                    hop_menu_append_section(submenu, section)
                    section = hop_menu_new()!
                case .button(let title, let action):
                    let name = "hop\(actionIndex)"
                    actionIndex += 1
                    let gaction = hop_simple_action_new(name)!
                    let box = GTK4ActionBox()
                    box.action = action
                    menuBoxes.append(box)
                    _ = hop_action_connect_activate(gaction, gtk4ActionCallback, Unmanaged.passUnretained(box).toOpaque())
                    hop_app_add_action(app, gaction)
                    hop_menu_append_item(section, title, "app.\(name)")
                case .command(let title, let command):
                    let name = "hop\(actionIndex)"
                    actionIndex += 1
                    let gaction = hop_simple_action_new(name)!
                    let clipboardAction = Self.clipboardAction(command)
                    let window = window
                    let box = GTK4ActionBox()
                    box.action = { hop_window_activate_clipboard(window, clipboardAction) }
                    menuBoxes.append(box)
                    _ = hop_action_connect_activate(gaction, gtk4ActionCallback, Unmanaged.passUnretained(box).toOpaque())
                    hop_app_add_action(app, gaction)
                    hop_menu_append_item(section, title, "app.\(name)")
                }
            }
            hop_menu_append_section(submenu, section)
            hop_menu_append_submenu(topMenu, spec.title, submenu)
        }
        hop_app_set_menubar(app, topMenu)
        hop_window_show_menubar(window)
    }

    private static func clipboardAction(_ command: StandardCommand) -> String {
        switch command {
        case .cut: return "clipboard.cut"
        case .copy: return "clipboard.copy"
        case .paste: return "clipboard.paste"
        case .selectAll: return "selection.select-all"
        case .undo: return "text.undo"
        case .redo: return "text.redo"
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

        // Modern GTK4 toolbar idiom: a GtkHeaderBar installed as the window's titlebar.
        let bar = hop_header_bar_new()!
        headerBar = bar
        toolbarBoxes = []
        hop_window_set_titlebar(window, bar)
        for item in items {
            switch item.kind {
            case .text(let string):
                hop_header_bar_pack_start(bar, hop_label_new(string)!)
            case .button(let title, let action):
                let button = hop_button_new(title)!
                let box = GTK4ActionBox()
                box.action = action
                toolbarBoxes.append(box)
                _ = hop_connect_clicked(button, gtk4ClickedCallback, Unmanaged.passUnretained(box).toOpaque())
                hop_header_bar_pack_start(bar, button)
            }
        }
    }
}
