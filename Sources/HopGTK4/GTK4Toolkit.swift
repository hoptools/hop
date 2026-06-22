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
    var isLabel = false   // a GtkLabel (Text) — measured with width-for-wrap
    var imageResizable = false
    var isProgress = false
    var isScroll = false  // a GtkScrolledWindow (its single child is the scrollable content)
    var isTextEditor = false  // a GtkTextView-in-GtkScrolledWindow (TextEditor) — measured greedily (fills both axes)
    var flexibleWidth = false  // text fields / sliders / progress bars fill the offered width (SwiftUI-like)
    var scrollHandler: (@MainActor (CGSize) -> Void)?
    var scrollConnected = false
    var pulseTimerId: UInt32 = 0  // GLib source id of the indeterminate-progress pulse timer (0 = none)
    // Guards against re-presenting a file dialog while one is already open (isPresented stays true).
    var importerPresenting = false
    var exporterPresenting = false
    // Action boxes for a drop-down menu's items, retained so their C callbacks stay valid.
    var retainedBoxes: [GTK4ActionBox] = []
    // For `.onTapGesture`: the retained callback box + the GtkGestureClick controller (so we can remove it).
    var tapBox: GTK4ActionBox?
    var tapGesture: UnsafeMutableRawPointer?
    // Controllers + retained boxes for the newer gestures (one slot each).
    var longPressGesture: UnsafeMutableRawPointer?
    var longPressBox: GTK4ActionBox?
    var hoverController: UnsafeMutableRawPointer?
    var hoverBox: GTK4ActionBox?
    var dragGestureController: UnsafeMutableRawPointer?
    var dragBox: GTK4ActionBox?
    var zoomGesture: UnsafeMutableRawPointer?
    var zoomBox: GTK4ActionBox?
    var rotateGestureController: UnsafeMutableRawPointer?
    var rotateBox: GTK4ActionBox?
    init(_ widget: UnsafeMutableRawPointer) { self.widget = widget }
}

/// Holds a file-dialog completion closure, passed (retained) as the C `user_data` so it survives the
/// async dialog even if the originating widget goes away. The callback releases it.
final class GTK4FileBox {
    let onComplete: (@MainActor ([URL]?) -> Void)
    init(_ onComplete: @escaping @MainActor ([URL]?) -> Void) { self.onComplete = onComplete }
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
    var tapAction: (@MainActor () -> Void)?   // `.onTapGesture`
    var tapCount = 1
    // Newer gestures: each setter makes a fresh box holding just the relevant closures.
    var longPress: (@MainActor () -> Void)?
    var onHover: (@MainActor (Bool) -> Void)?
    var dragChanged: (@MainActor (DragGesture.Value) -> Void)?
    var dragEnded: (@MainActor (DragGesture.Value) -> Void)?
    var magnifyChanged: (@MainActor (MagnifyGesture.Value) -> Void)?
    var rotateChanged: (@MainActor (RotateGesture.Value) -> Void)?
    var onChange: (@MainActor (String) -> Void)?
    var onSubmit: (@MainActor () -> Void)?
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
    var suppressTextEditor = false   // raised while reflecting the bound value into a TextEditor's buffer
    /// Color-picker change callback (RGBA, each 0..1). "color-set" only fires on a user pick, so no guard.
    var onChangeColor: (@MainActor (Double, Double, Double, Double) -> Void)?
    /// Outline (tree) state: the pre-order flattened rows the C row callbacks read, a structure signature
    /// for rebuild detection, the last reflected selection key, and the key→selection callback.
    var treeFlat: [(key: String, title: String, depth: Int, selectable: Bool)] = []
    var treeSignature: String?
    var lastSelectedKey: String?
    var onSelectKey: (@MainActor (String?) -> Void)?
    /// Keys of non-selectable group-header rows. `GtkSingleSelection` has no per-row selectability, so the
    /// selection callback reverts a header click back to the last valid selection (see the callback).
    var headerKeys: Set<String> = []
    /// Current shape to draw, read by the GtkDrawingArea draw callback (for `.shape` widgets).
    var shape: ShapeSpec?
    /// Layout frame size (from `.frame`) and the transform bleed offset, so the draw callback can paint
    /// the frame-sized shape at the right spot within the (possibly enlarged) drawing area.
    var frameWidth: Double = 0
    var frameHeight: Double = 0
    var bleedX: Double = 0
    var bleedY: Double = 0
}

// Screenshot-harness tracing: HOP_PLAYGROUND_ID is set only by the CI screenshot script. Writes to stderr
// (unbuffered) so a step that blocks still leaves a trail. Used to localise where GTK app bring-up stalls on
// the headless runner (e.g. GApplication blocking on session-bus registration before `activate` fires).
func gtk4Trace(_ message: String) {
    if ProcessInfo.processInfo.environment["HOP_PLAYGROUND_ID"] != nil {
        FileHandle.standardError.write(Data("[hop-gtk] \(message)\n".utf8))
    }
}

// Top-level (non-capturing) C callbacks. C function pointers cannot capture, so context is passed
// through the GTK `user_data` argument and recovered via `Unmanaged`.

private let gtk4ActivateCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { app, userData in
    guard let app, let userData else { return }
    let context = Unmanaged<GTK4RunContext>.fromOpaque(userData).takeUnretainedValue()
    let appPointer = SendableGTKPointer(raw: app)

    // GTK invokes `activate` on the main thread, so assert main-actor isolation to build the window.
    MainActor.assumeIsolated {
        // HOP_PLAYGROUND_ID is set only by the CI screenshot harness; use it to switch on the present-first
        // window-mapping workaround below (gtk4Trace already keys off the same var). Normal launches unaffected.
        let screenshotMode = ProcessInfo.processInfo.environment["HOP_PLAYGROUND_ID"] != nil

        gtk4Trace("activate: create window")
        let window = hop_window_new(appPointer.raw)!
        context.toolkit.window = window
        hop_window_set_title(window, context.title)
        // Honor HOP_WINDOW_SIZE (uniform screenshot size) for the primary window; default 820×760.
        let requested = hopRequestedWindowSize()
        hop_window_set_default_size(window, Int32(requested?.width ?? 820), Int32(requested?.height ?? 760))

        // An absolute-positioning GtkFixed is the mount point the layout engine sizes/positions the root
        // within. It sits inside a root wrapper (`hop_root_container_new`) — a GtkFixed whose layout
        // manager is HopRootLayout — which is the window's child. That layout manager reports a zero
        // minimum (so GtkWindow imposes no minimum and the window resizes freely both ways) and, on every
        // allocate (GTK's natural "the content area changed" hook), re-runs the layout engine for the new
        // size and fills the mount point. The idiomatic way to drive a foreign layout system from GTK: no
        // window min ratchet, no resize-signal polling.
        let container = hop_fixed_new()!
        let wrapper = hop_root_container_new()!
        hop_root_container_set_child(wrapper, container)
        hop_window_set_child(window, wrapper)
        context.toolkit.rootContainer = container
        context.toolkit.rootWrapper = wrapper

        let toolkitPtr = Unmanaged.passUnretained(context.toolkit).toOpaque()
        hop_root_container_set_relayout(wrapper, gtk4RelayoutCallback, toolkitPtr)

        // Window mapping order. Normally we mount the HopUI tree first (which sets a custom titlebar /
        // header bar via setToolbar, making this a client-side-decorated window) and THEN present — that's
        // correct on a real desktop. But under the headless CI Xvfb a CSD toplevel never maps (it stays
        // created-but-unmapped at 1×1, so every screenshot came out blank). In screenshot mode we therefore
        // present FIRST: the shell maps immediately as an ordinary server-side-decorated window (openbox
        // provides the frame), then the mount fills it via the allocate hook. The trade-off — the custom
        // header bar is set on an already-realized window (a benign GTK warning, server-side frame instead) —
        // is fine for the gallery. Real apps keep the original order, so their header bar is unaffected.
        if screenshotMode {
            gtk4Trace("activate: present window (screenshot mode)")
            hop_window_present(window)
            gtk4Trace("activate: mount begin")
            context.onReady(GTK4Widget(container))
            gtk4Trace("activate: mount end")
        } else {
            context.onReady(GTK4Widget(container))
            hop_window_present(window)
        }
    }
}

private let gtk4ClickedCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.action?() }
}

// GtkGestureClick "released" (`.onTapGesture`): fires the handler only on the Nth press (n_press == count).
private let gtk4TapCallback: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, nPress, _, _, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { if Int(nPress) == box.tapCount { box.tapAction?() } }
}

private let gtk4LongPressCallback: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, _, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.longPress?() }
}

private let gtk4HoverEnterCallback: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, _, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onHover?(true) }
}
private let gtk4HoverLeaveCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onHover?(false) }
}

// Build a DragGesture.Value from the gesture's start point (read via the shim) + the reported offset.
private func gtk4DragValue(_ gesture: UnsafeMutableRawPointer, _ ox: Double, _ oy: Double) -> DragGesture.Value {
    var sx = 0.0, sy = 0.0
    hop_drag_get_start(gesture, &sx, &sy)
    return DragGesture.Value(startLocation: CGPoint(x: sx, y: sy),
                             location: CGPoint(x: sx + ox, y: sy + oy),
                             translation: CGSize(width: ox, height: oy))
}
private let gtk4DragUpdateCallback: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { gesture, ox, oy, userData in
    guard let gesture, let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    let value = gtk4DragValue(gesture, ox, oy)
    MainActor.assumeIsolated { box.dragChanged?(value) }
}
private let gtk4DragEndCallback: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { gesture, ox, oy, userData in
    guard let gesture, let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    let value = gtk4DragValue(gesture, ox, oy)
    MainActor.assumeIsolated { box.dragEnded?(value) }
}

private let gtk4ZoomCallback: @convention(c) (UnsafeMutableRawPointer?, Double, UnsafeMutableRawPointer?) -> Void = { _, scale, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.magnifyChanged?(MagnifyGesture.Value(magnification: CGFloat(scale))) }
}
private let gtk4RotateCallback: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, delta, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.rotateChanged?(RotateGesture.Value(rotation: Angle(radians: delta))) }
}

private let gtk4ChangedCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { entry, userData in
    guard let entry, let userData, let cText = hop_editable_get_text(entry) else { return }
    let text = String(cString: cText)
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onChange?(text) }
}

// TextEditor buffer "changed" callback — fires (GtkTextBuffer*, user_data); read the buffer's text. Suppressed
// while reflecting the bound value so a programmatic set doesn't echo back as a user edit.
private let gtk4TextViewChangedCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { buffer, userData in
    guard let buffer, let userData, let cText = hop_text_buffer_get_text(buffer) else { return }
    let text = String(cString: cText)
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        guard !box.suppressTextEditor else { return }
        box.onChange?(text)
    }
}

// GtkEntry "activate" (Return pressed) → `.onSubmit`.
private let gtk4ActivateEntryCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onSubmit?() }
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

// Fired on a GtkColorButton user pick; reads RGBA off the emitting button.
private let gtk4ColorSetCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { button, userData in
    guard let button, let userData else { return }
    let r = hop_colorbutton_red(button), g = hop_colorbutton_green(button)
    let b = hop_colorbutton_blue(button), a = hop_colorbutton_alpha(button)
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onChangeColor?(r, g, b, a) }
}

// Fired when a GtkFileChooserNative finishes: `paths` is newline-joined absolute paths, or nil on cancel.
private let gtk4FileCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { paths, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4FileBox>.fromOpaque(userData).takeRetainedValue()
    let urls: [URL]? = paths.map { String(cString: $0).split(separator: "\n").map { URL(fileURLWithPath: String($0)) } }
    MainActor.assumeIsolated { box.onComplete(urls) }
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
private let gtk4TreeSelectableCallback: @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Int32 = { position, userData in
    guard let userData else { return 1 }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated { (box.treeFlat.indices.contains(Int(position)) ? box.treeFlat[Int(position)].selectable : true) ? 1 : 0 }
}

// Tree selection (notify::selected): read the selected row's key and report it. user_data is the handle.
private let gtk4TreeSelectionCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, userData in
    guard let userData else { return }
    let handle = Unmanaged<GTK4Widget>.fromOpaque(userData).takeUnretainedValue()
    let key: String? = hop_tree_get_selected_key(handle.widget).map { let s = String(cString: $0); free($0); return s }
    MainActor.assumeIsolated {
        guard let box = handle.actionBox else { return }
        // A non-selectable group header was clicked: GtkSingleSelection can't refuse a row, so revert to
        // the last valid selection (re-fires this callback once with that key, absorbed by the guard below).
        if let key, box.headerKeys.contains(key) {
            hop_tree_select_key(handle.widget, box.lastSelectedKey)
            return
        }
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

// Button-group (Picker .segmented / .radioGroup) selection callback: the activated button's index.
private let gtk4ButtonGroupCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { index, userData in
    guard let userData else { return }
    let box = Unmanaged<GTK4ActionBox>.fromOpaque(userData).takeUnretainedValue()
    let i = Int(index)
    MainActor.assumeIsolated {
        if box.lastSelected != i {
            box.lastSelected = i
            box.onSelect?(i)
        }
    }
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

// Invoked from HopRootLayout's allocate (GTK's natural resize hook) to re-run the layout engine for the
// new content size. Deferred to an idle tick rather than run inline: the engine sets child size-requests
// (`gtk_widget_queue_resize`), and doing that *during* allocate makes GTK renegotiate the window to the
// content's natural size. Running it just after the allocate settles keeps the window the size the user
// chose and reflows the content within it.
private let gtk4RelayoutCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
    guard let userData else { return }
    let toolkit = Unmanaged<GTK4Toolkit>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { toolkit.scheduleOnMainThread {
        // Re-laying-out sets child size-requests, which queue a resize and call us again at the SAME size.
        // Skip when the content area is unchanged to break that feedback loop. (Content changes relayout
        // through a separate path; the engine now computes the split detail width, so one pass per size is
        // enough — no need to re-run until native sizes settle.)
        let size = toolkit.contentSize()
        guard size != toolkit.lastResizeSize else { return }
        toolkit.lastResizeSize = size
        toolkit.relayoutHandler?()
    } }
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
    /// Widgets currently packed into the header bar by `setToolbar`, so they can be removed when the
    /// toolbar changes without rebuilding the bar (which would drop the centered navigation title).
    private var toolbarItemWidgets: [UnsafeMutableRawPointer] = []
    /// The navigation title currently shown in the header bar's centered title slot (nil = none).
    private var navigationTitleString: String?
    private var menuBoxes: [GTK4ActionBox] = []
    private var menuSignature: String?
    // Secondary windows (e.g. About) are kept here for the app's lifetime.
    private var secondaryWindows: [UnsafeMutableRawPointer] = []
    // The mount-point GtkFixed the layout engine fills; the engine pins its children's sizes (so its own
    // size tracks the content, not the window). The wrapper it sits in gives the true content area.
    var rootContainer: UnsafeMutableRawPointer?
    // The zero-minimum root wrapper (HopRootLayout) holding `rootContainer`; its allocated size is the
    // layout root proposal (the mount-point GtkFixed is sized to the content, not the window content area).
    var rootWrapper: UnsafeMutableRawPointer?
    // The content size of the last resize-triggered relayout, to skip redundant re-layouts at the same size.
    var lastResizeSize: CGSize?
    // Called by the runtime to re-run the layout engine when the window content size changes.
    var relayoutHandler: (@MainActor () -> Void)?

    // MARK: - Open component system
    public static let toolkitID = ToolkitID.gtk4
    public let components = ComponentRegistry<GTK4Widget>()

    public init() { registerBuiltinComponents() }

    public func realize(_ component: any WidgetComponent) -> GTK4Widget {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.make(component) }
        if let ptr = component.makeNative(Self.toolkitID) as? UnsafeMutableRawPointer { return GTK4Widget(ptr) }
        assertionFailure("HopUI/GTK4: no renderer registered for WidgetKey \"\(component.widgetKey.rawValue)\", and the component self-hosts no GtkWidget")
        return makeNativeWidget(.vstack)
    }

    public func updateComponent(_ handle: GTK4Widget, _ component: any WidgetComponent) {
        if let renderer = components.renderer(for: component.widgetKey) { renderer.update(handle, component); return }
        component.updateNative(handle.widget, Self.toolkitID)
    }

    public func measureComponent(_ handle: GTK4Widget, _ component: any WidgetComponent, _ proposal: ProposedViewSize) -> CGSize {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.measure(handle, component, proposal) }
        switch component.role {
        case .fill, .native: return proposal.resolved(.zero)
        default: return measure(handle, proposal)
        }
    }

    public func didInsertChildren(_ handle: GTK4Widget, _ component: any WidgetComponent) {
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
            .label, .button, .textField, .secureField, .textEditor,
            .slider, .progress, .separator,
        ] + ToggleStyle.allCases.map { .toggle($0) }   // toggle.switch / .checkbox / .button / .automatic
        for key in leaves {
            components.register(.init(
                make: { [unowned self] component in let handle = makeNativeWidget(key); applyLeaf(handle, component); return handle },
                update: { [unowned self] handle, component in applyLeaf(handle, component) },
                measure: { [unowned self] handle, _, proposal in measure(handle, proposal) }
            ), for: key)
        }
    }

    private func applyLeaf(_ handle: GTK4Widget, _ component: any WidgetComponent) {
        guard let leaf = component as? PrimitiveLeafComponent else { return }
        configure(handle, leaf.patch)
        setAction(handle, leaf.action)
        setTextHandler(handle, leaf.onChange)
        setValueHandler(handle, leaf.onChangeDouble)
        setBoolHandler(handle, leaf.onChangeBool)
    }

    /// `Picker` renderers — each style is a distinct native widget under its own key (the reconciler
    /// recreates the widget when the style changes). `.menu`/`.automatic` → GtkDropDown; `.segmented` → a
    /// horizontal row of linked toggle buttons; `.radioGroup` → a vertical group of radio (check) buttons.
    private func registerPickerComponents() {
        let dropdown = ComponentRegistry<GTK4Widget>.Renderer(
            make: { [unowned self] component in
                let handle = makeNativeWidget(.picker)
                if let spec = (component as? PickerComponent)?.spec { configurePicker(handle, spec) }
                return handle
            },
            update: { [unowned self] handle, component in
                if let spec = (component as? PickerComponent)?.spec { configurePicker(handle, spec) }
            },
            measure: { [unowned self] handle, _, proposal in measure(handle, proposal) })
        components.register(dropdown, for: .picker(.menu))
        components.register(dropdown, for: .picker(.automatic))

        for (style, horizontal, toggle) in [(PickerStyle.segmented, true, true), (PickerStyle.radioGroup, false, false)] {
            components.register(.init(
                make: { [unowned self] component in
                    let handle = makeButtonGroup(horizontal: horizontal)
                    if let spec = (component as? PickerComponent)?.spec { configureButtonGroupPicker(handle, spec, toggle: toggle) }
                    return handle
                },
                update: { [unowned self] handle, component in
                    if let spec = (component as? PickerComponent)?.spec { configureButtonGroupPicker(handle, spec, toggle: toggle) }
                },
                measure: { [unowned self] handle, _, proposal in measure(handle, proposal) }
            ), for: .picker(style))
        }

        // .inline → a GtkListBox: every option a selectable row (in line with surrounding content).
        components.register(.init(
            make: { [unowned self] component in
                let handle = makeInlinePicker()
                if let spec = (component as? PickerComponent)?.spec { configureInlinePicker(handle, spec) }
                return handle
            },
            update: { [unowned self] handle, component in
                if let spec = (component as? PickerComponent)?.spec { configureInlinePicker(handle, spec) }
            },
            measure: { [unowned self] handle, _, proposal in measure(handle, proposal) }
        ), for: .picker(.inline))
    }

    /// Build an inline-picker widget: a GtkListBox of selectable rows.
    private func makeInlinePicker() -> GTK4Widget {
        let widget = hop_listbox_new()!
        hop_object_ref_sink(widget)
        let handle = GTK4Widget(widget)
        handle.actionBox = GTK4ActionBox()
        return handle
    }

    /// Configure the inline picker: (re)populate the list rows when options change, otherwise reflect the
    /// bound selection. Reuses `gtk4ButtonGroupCallback` (it just forwards the selected index).
    private func configureInlinePicker(_ handle: GTK4Widget, _ spec: PickerSpec) {
        guard let box = handle.actionBox else { return }
        box.onSelect = { if let index = $0 { spec.onSelect(index) } }
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        if box.pickerOptions != spec.options {
            box.pickerOptions = spec.options
            box.rowText = { spec.options[$0] }
            hop_listbox_set_items(handle.widget, UInt32(spec.options.count), gtk4RowCallback,
                                  Int32(spec.selectedIndex ?? -1), gtk4ButtonGroupCallback, boxPtr)
            box.lastSelected = spec.selectedIndex
        } else if box.lastSelected != spec.selectedIndex {
            box.lastSelected = spec.selectedIndex
            hop_listbox_set_selected(handle.widget, Int32(spec.selectedIndex ?? -1))
        }
    }

    /// Build a button-group picker widget (segmented = horizontal/linked toggle buttons; radio = vertical).
    private func makeButtonGroup(horizontal: Bool) -> GTK4Widget {
        let widget = hop_buttongroup_new(horizontal ? 1 : 0)!
        hop_object_ref_sink(widget)
        let handle = GTK4Widget(widget)
        handle.actionBox = GTK4ActionBox()
        return handle
    }

    /// Configure a segmented / radio-group picker: (re)populate when the options change, otherwise just
    /// reflect the bound selection. `toggle` selects toggle-button (segmented) vs check-button (radio) items.
    private func configureButtonGroupPicker(_ handle: GTK4Widget, _ spec: PickerSpec, toggle: Bool) {
        guard let box = handle.actionBox else { return }
        box.onSelect = { if let index = $0 { spec.onSelect(index) } }
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        if box.pickerOptions != spec.options {
            box.pickerOptions = spec.options
            box.rowText = { spec.options[$0] }
            hop_buttongroup_set_items(handle.widget, UInt32(spec.options.count), gtk4RowCallback,
                                      Int32(spec.selectedIndex ?? -1), toggle ? 1 : 0, gtk4ButtonGroupCallback, boxPtr)
            box.lastSelected = spec.selectedIndex
        } else if box.lastSelected != spec.selectedIndex {
            box.lastSelected = spec.selectedIndex
            hop_buttongroup_set_selected(handle.widget, Int32(spec.selectedIndex ?? -1))
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

    public func makeNativeWidget(_ key: WidgetKey) -> GTK4Widget {
        let widget: UnsafeMutableRawPointer
        switch key {
        // Box-model containers are absolute-positioning GtkFixed layers; the layout engine owns geometry.
        case .vstack, .hstack, .zstack, .spacer, .window, .geometry, .lazyStack: widget = hop_fixed_new()!
        case .groupBox:
            widget = hop_fixed_new()!
            hop_widget_add_css_class(widget, "card")  // Adwaita's rounded, bordered, filled card chrome
        case .scroll: widget = hop_scrolled_window_new()!  // a real clipping/scrolling viewport
        case .label:  widget = hop_label_new("")!
        case .button: widget = hop_button_new("")!
        case .textField: widget = hop_entry_new()!
        case .textEditor: widget = hop_textview_new()!
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
        case let k where k.rawValue.hasPrefix("toggle."):
            switch ToggleStyle(rawValue: String(k.rawValue.dropFirst("toggle.".count))) ?? .automatic {
            case .checkbox: widget = hop_check_button_new()!
            case .button: widget = hop_toggle_button_new()!
            case .switch, .automatic: widget = hop_switch_new()!
            }
        case .secureField:
            widget = hop_entry_new()!
            hop_entry_set_visibility(widget, 0)  // mask typed characters (password field)
        case .shape: widget = hop_drawing_area_new()!
        case .menu: widget = hop_menu_button_new()!
        case .picker: widget = hop_dropdown_new()!
        case .datePicker: widget = hop_datepicker_new()!
        case .colorPicker: widget = hop_colorbutton_new()!
        case .progress: widget = hop_progress_bar_new()!
        case .separator:
            widget = hop_separator_new(1)!  // a divider between stacked rows is a horizontal line
        default:
            // Only registered renderers call this, with keys this switch knows — an unknown key is a bug.
            assertionFailure("HopUI/GTK4: makeNativeWidget has no native widget for key \"\(key.rawValue)\"")
            widget = hop_fixed_new()!  // degrade to a plain layer in release
        }
        // Take an owning reference so our handle stays valid across reparenting/removal.
        hop_object_ref_sink(widget)
        let handle = GTK4Widget(widget)
        if key == .textField || key == .secureField || key == .slider || key == .progress { handle.flexibleWidth = true }

        if key == .button {
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_connect_clicked(widget, gtk4ClickedCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if key == .textField || key == .secureField {
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_connect_changed(widget, gtk4ChangedCallback, Unmanaged.passUnretained(box).toOpaque())
            _ = hop_connect_activate(widget, gtk4ActivateEntryCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if key == .textEditor {
            handle.isTextEditor = true
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_textview_connect_changed(widget, gtk4TextViewChangedCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if key.rawValue.hasPrefix("toggle.") {
            // switch / checkbox / push-toggle button — all expose "active" (notify::active), read type-aware.
            handle.isToggle = true
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_switch_connect(widget, gtk4SwitchCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if key == .slider {
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_connect_value_changed(widget, gtk4ValueChangedCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if key == .list || key == .sidebarList {
            // The selection signal is connected in configureList, after the model is built.
            handle.actionBox = GTK4ActionBox()
        } else if key == .outline || key == .sidebarOutline {
            // The selection signal is connected in configureOutline, after the tree model is built.
            handle.actionBox = GTK4ActionBox()
        } else if key == .shape {
            handle.isShape = true
            let box = GTK4ActionBox()
            handle.actionBox = box
            hop_drawing_area_set_draw_func(widget, gtk4DrawCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if key == .image {
            handle.isImage = true
        } else if key == .label {
            handle.isLabel = true   // measured with width-for-wrap (GtkLabel wraps like SwiftUI Text)
            hop_label_set_wrapping(widget)  // wrap ONLY Text leaves, not chrome labels (e.g. toolbar items)
        } else if key == .picker {
            // Selection signal is connected in configurePicker after the model is set.
            handle.actionBox = GTK4ActionBox()
        } else if key == .datePicker {
            // Sub-widget signals are connected in configureDatePicker (once components are known).
            handle.actionBox = GTK4ActionBox()
        } else if key == .colorPicker {
            let box = GTK4ActionBox()
            handle.actionBox = box
            _ = hop_colorbutton_connect(widget, gtk4ColorSetCallback, Unmanaged.passUnretained(box).toOpaque())
        } else if key == .progress {
            handle.isProgress = true
        } else if key == .splitView {
            handle.isSplit = true
        } else if key == .tabView {
            handle.isTabView = true
            handle.actionBox = GTK4ActionBox()  // switch-page signal connected in configureTabs
        } else if key == .scroll {
            handle.isScroll = true
        }
        return handle
    }

    public func configure(_ handle: GTK4Widget, _ patch: WidgetPatch) {
        if let text = patch.text { hop_label_set_text(handle.widget, text) }
        if let title = patch.title { hop_button_set_label(handle.widget, title) }
        if let placeholder = patch.placeholder { hop_entry_set_placeholder(handle.widget, placeholder) }
        if let value = patch.value, handle.isTextEditor, let box = handle.actionBox {
            // The widget is a GtkScrolledWindow (not editable) — reflect via the buffer, suppressing the
            // "changed" callback so it doesn't echo back / move the cursor.
            let current = hop_textview_get_text(handle.widget).map { String(cString: $0) } ?? ""
            if current != value {
                box.suppressTextEditor = true
                hop_textview_set_text(handle.widget, value)
                box.suppressTextEditor = false
            }
        } else if let value = patch.value {
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

        // `.opacity` (composites the subtree) and `.disabled` (GTK's sensitivity is hierarchical, so setting
        // it on a container cascades to descendant controls).
        hop_widget_set_opacity(handle.widget, patch.opacity ?? 1)
        if let enabled = patch.isEnabled { hop_widget_set_sensitive(handle.widget, enabled ? 1 : 0) }

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
        // `.accessibilityIdentifier` → the widget name (GTK's programmatic id; analogous to Qt's objectName).
        if let identifier = patch.accessibilityIdentifier { hop_a11y_identifier(handle.widget, identifier) }
    }

    /// Builds an inline CSS rule (wrapped in `* { }` for the widget node) for the patch's styling.
    private static func cssStyle(_ patch: WidgetPatch) -> String? {
        var rules: [String] = []
        if let fg = patch.foregroundColor { rules.append("color: \(fg.cssRGBA)") }
        if let bg = patch.backgroundColor { rules.append("background-color: \(bg.cssRGBA)") }
        if let font = patch.font {
            rules.append("font-size: \(Int(font.size.rounded()))px")
            // `.monospaced` overrides any named family with the generic monospace family.
            if patch.monospaced == true { rules.append("font-family: monospace") }
            else if let family = font.family { rules.append("font-family: \"\(family)\"") }
        } else if patch.monospaced == true {
            rules.append("font-family: monospace")   // monospaced default-size text (no explicit font)
        }
        if let weight = patch.fontWeight ?? patch.font?.weight {
            rules.append("font-weight: \(weight.cssValue)")
        }
        if patch.italic == true { rules.append("font-style: italic") }
        if let align = patch.textAlignment {
            rules.append("text-align: \(align == .leading ? "start" : align == .center ? "center" : "end")")
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

    public func setSubmitHandler(_ handle: GTK4Widget, _ handler: (@MainActor () -> Void)?) {
        handle.actionBox?.onSubmit = handler
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
        box.headerKeys = Set(flat.filter { !$0.node.selectable }.map { $0.node.key })

        // Rebuild the native tree only when the structure changes (not on every reconcile, which would
        // collapse expansion and re-trigger selection); the model + selection signal are recreated here.
        let signature = spec.structureSignature
        if box.treeSignature != signature {
            box.treeSignature = signature
            box.treeFlat = flat.map { (key: $0.node.key, title: $0.node.title, depth: $0.depth, selectable: $0.node.selectable) }
            let boxPtr = Unmanaged.passUnretained(box).toOpaque()
            hop_tree_set_rows(handle.widget, UInt32(flat.count),
                              gtk4TreeTitleCallback, gtk4TreeKeyCallback, gtk4TreeDepthCallback,
                              gtk4TreeSelectableCallback, boxPtr)
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

    public func configureColorPicker(_ handle: GTK4Widget, _ spec: ColorPickerSpec) {
        guard let box = handle.actionBox else { return }
        box.onChangeColor = { r, g, b, a in spec.onChange(Color(red: r, green: g, blue: b, opacity: a)) }
        hop_colorbutton_set_alpha(handle.widget, spec.supportsOpacity ? 1 : 0)
        // Programmatic set_rgba doesn't emit "color-set", so this won't re-fire the handler.
        hop_colorbutton_set(handle.widget, spec.color.red, spec.color.green, spec.color.blue, spec.color.opacity)
    }

    /// (filterName, ";"-joined glob patterns) for a set of content types; empty patterns ⇒ all files.
    private func gtkFilter(_ types: [UTType]) -> (String, String) {
        let patterns = types.flatMap { $0.filenameExtensions }.map { "*.\($0)" }.joined(separator: ";")
        return (types.first?.displayName ?? "Files", patterns)
    }

    public func configureFileImporter(_ handle: GTK4Widget, _ spec: FileImporterSpec) {
        guard spec.isPresented else { handle.importerPresenting = false; return }
        guard !handle.importerPresenting else { return }
        handle.importerPresenting = true
        let box = GTK4FileBox { [weak handle] urls in
            handle?.importerPresenting = false
            spec.setPresented(false)
            if let urls { spec.onCompletion(.success(urls)) }   // nil ⇒ cancel, no completion
        }
        let (name, patterns) = gtkFilter(spec.allowedContentTypes)
        hop_file_open(handle.widget, spec.allowsMultipleSelection ? 1 : 0, name, patterns,
                      gtk4FileCallback, Unmanaged.passRetained(box).toOpaque())
    }

    public func configureFileExporter(_ handle: GTK4Widget, _ spec: FileExporterSpec) {
        guard spec.isPresented else { handle.exporterPresenting = false; return }
        guard !handle.exporterPresenting else { return }
        handle.exporterPresenting = true
        let box = GTK4FileBox { [weak handle] urls in
            handle?.exporterPresenting = false
            spec.setPresented(false)
            guard let url = urls?.first else { return }   // nil ⇒ cancel
            do { try spec.data.write(to: url); spec.onCompletion(.success(url)) }
            catch { spec.onCompletion(.failure(error)) }
        }
        let (name, patterns) = gtkFilter([spec.contentType])
        hop_file_save(handle.widget, spec.defaultFilename, name, patterns,
                      gtk4FileCallback, Unmanaged.passRetained(box).toOpaque())
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
        // TextEditor (role .fill) greedily fills the offered space along both axes (default when unconstrained).
        if handle.isTextEditor {
            return proposal.resolved(CGSize(width: 240, height: 140))
        }
        // A label (Text) wraps to the proposed width: report the wrapped height, not the single-line width.
        if handle.isLabel {
            var lw: Int32 = 0, lh: Int32 = 0
            let forWidth = (proposal.width?.isFinite == true) ? Int32(Swift.max(0, proposal.width!)) : -1
            hop_label_measure(handle.widget, forWidth, &lw, &lh)
            return CGSize(width: Double(lw), height: Double(lh))
        }
        var w: Int32 = 0, h: Int32 = 0
        hop_widget_measure(handle.widget, -1, &w, &h)  // natural/intrinsic size
        // Flexible-width controls (text fields, sliders, progress bars) take EXACTLY the offered width —
        // both growing and SHRINKING with it (SwiftUI-like). Clamping up to the natural width (the old
        // `max(pw, natural)`) made them refuse to shrink below their natural size, so a shrinking window
        // left them wider than it and truncated. GTK still honors each control's own intrinsic minimum.
        if handle.flexibleWidth, let pw = proposal.width, pw.isFinite {
            return CGSize(width: pw, height: Double(h))
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

    public func setTapHandler(_ handle: GTK4Widget, _ spec: TapGestureSpec?) {
        if let gesture = handle.tapGesture {
            hop_tap_gesture_remove(handle.widget, gesture)
            handle.tapGesture = nil; handle.tapBox = nil
        }
        guard let spec else { return }
        let box = GTK4ActionBox()
        box.tapAction = spec.action
        box.tapCount = Swift.max(1, spec.count)
        handle.tapBox = box   // retain so the C callback's user_data stays valid
        handle.tapGesture = hop_tap_gesture_new(handle.widget, gtk4TapCallback, Unmanaged.passUnretained(box).toOpaque())
    }

    public func setLongPressHandler(_ handle: GTK4Widget, _ spec: LongPressGestureSpec?) {
        if let g = handle.longPressGesture { hop_controller_remove(handle.widget, g); handle.longPressGesture = nil; handle.longPressBox = nil }
        guard let spec else { return }
        let box = GTK4ActionBox(); box.longPress = spec.action
        handle.longPressBox = box
        // GTK's default long-press time is ~0.5 s; scale it (clamped) to approximate the requested duration.
        let factor = Swift.max(0.5, Swift.min(4.0, spec.minimumDuration / 0.5))
        handle.longPressGesture = hop_longpress_gesture_new(handle.widget, factor, gtk4LongPressCallback,
                                                            Unmanaged.passUnretained(box).toOpaque())
    }

    public func setHoverHandler(_ handle: GTK4Widget, _ handler: (@MainActor (Bool) -> Void)?) {
        if let c = handle.hoverController { hop_controller_remove(handle.widget, c); handle.hoverController = nil; handle.hoverBox = nil }
        guard let handler else { return }
        let box = GTK4ActionBox(); box.onHover = handler
        handle.hoverBox = box
        handle.hoverController = hop_hover_controller_new(handle.widget, gtk4HoverEnterCallback, gtk4HoverLeaveCallback,
                                                         Unmanaged.passUnretained(box).toOpaque())
    }

    // The gesture handlers are IDEMPOTENT: the reconciler re-applies them on every render, so the native
    // controller is created ONCE and kept alive — only the box's closures are refreshed (they capture the
    // latest @State). Tearing the controller down + re-adding it on each render would cancel an in-flight
    // gesture mid-drag (the new controller never saw the button-press), which is why drag/magnify/rotate
    // appeared dead. Create/destroy only on a nil↔non-nil transition.
    public func setDragHandler(_ handle: GTK4Widget, _ spec: DragGestureSpec?) {
        guard let spec else {
            if let g = handle.dragGestureController { hop_controller_remove(handle.widget, g); handle.dragGestureController = nil; handle.dragBox = nil }
            return
        }
        if let box = handle.dragBox { box.dragChanged = spec.onChanged; box.dragEnded = spec.onEnded; return }
        let box = GTK4ActionBox(); box.dragChanged = spec.onChanged; box.dragEnded = spec.onEnded
        handle.dragBox = box
        handle.dragGestureController = hop_drag_gesture_new(handle.widget, gtk4DragUpdateCallback, gtk4DragEndCallback,
                                                           Unmanaged.passUnretained(box).toOpaque())
    }

    // NOTE: GtkGestureZoom/GtkGestureRotate need two simultaneous touch points, so they only fire on a real
    // touchscreen (Linux Wayland). On mouse-only desktops, X11, and the macOS GDK backend they never fire —
    // a GDK/platform limitation, not a wiring bug (see Gestures.swift). The wiring below is correct so they
    // work where touch is available.
    public func setMagnifyHandler(_ handle: GTK4Widget, _ spec: MagnifyGestureSpec?) {
        guard let spec else {
            if let g = handle.zoomGesture { hop_controller_remove(handle.widget, g); handle.zoomGesture = nil; handle.zoomBox = nil }
            return
        }
        if let box = handle.zoomBox { box.magnifyChanged = spec.onChanged; return }
        let box = GTK4ActionBox(); box.magnifyChanged = spec.onChanged   // GtkGestureZoom reports onChanged via scale-changed
        handle.zoomBox = box
        handle.zoomGesture = hop_zoom_gesture_new(handle.widget, gtk4ZoomCallback, Unmanaged.passUnretained(box).toOpaque())
    }

    public func setRotateHandler(_ handle: GTK4Widget, _ spec: RotateGestureSpec?) {
        guard let spec else {
            if let g = handle.rotateGestureController { hop_controller_remove(handle.widget, g); handle.rotateGestureController = nil; handle.rotateBox = nil }
            return
        }
        if let box = handle.rotateBox { box.rotateChanged = spec.onChanged; return }
        let box = GTK4ActionBox(); box.rotateChanged = spec.onChanged
        handle.rotateBox = box
        handle.rotateGestureController = hop_rotate_gesture_new(handle.widget, gtk4RotateCallback, Unmanaged.passUnretained(box).toOpaque())
    }

    public func contentSize() -> CGSize {
        // Read the WRAPPER (the window's actual content area), not the mount-point GtkFixed: the engine
        // pins that GtkFixed to the content size, so only the wrapper reflects the window shrinking.
        guard let wrapper = rootWrapper ?? rootContainer else { return CGSize(width: 820, height: 760) }
        var w: Int32 = 0, h: Int32 = 0
        hop_widget_get_size(wrapper, &w, &h)
        if w <= 0 || h <= 0 { return CGSize(width: 820, height: 760) }  // before first allocation
        return CGSize(width: Double(w), height: Double(h))
    }

    public func setRelayoutHandler(_ handler: @escaping @MainActor () -> Void) {
        relayoutHandler = handler  // invoked by gtk4RelayoutCallback when HopRootLayout is allocated a new size
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

        if let gradient = spec.gradient {
            fillGradient(gradient, rect: rect, cr: cr)
        } else if let fill = spec.fill {
            cairo_set_source_rgba(cr, fill.red, fill.green, fill.blue, fill.opacity)
            if spec.stroke != nil { cairo_fill_preserve(cr) } else { cairo_fill(cr) }
        }
        if let stroke = spec.stroke {
            cairo_set_source_rgba(cr, stroke.red, stroke.green, stroke.blue, stroke.opacity)
            cairo_set_line_width(cr, Double(spec.lineWidth))
            cairo_stroke(cr)
        }
    }

    /// Fill the current Cairo path with a gradient. Linear/radial use Cairo patterns; angular (no Cairo
    /// primitive) is rendered as a fan of interpolated wedges clipped to the path. Consumes the path.
    static func fillGradient(_ spec: GradientSpec, rect: CGRect, cr: OpaquePointer) {
        switch spec.kind {
        case .linear(let start, let end):
            let p0 = start.point(in: rect), p1 = end.point(in: rect)
            guard let pat = cairo_pattern_create_linear(Double(p0.x), Double(p0.y), Double(p1.x), Double(p1.y)) else { return }
            addStops(spec.stops, to: pat)
            cairo_set_source(cr, pat)
            cairo_fill(cr)
            cairo_pattern_destroy(pat)
        case .radial(let center, let r0, let r1):
            let c = center.point(in: rect)
            guard let pat = cairo_pattern_create_radial(Double(c.x), Double(c.y), Double(r0), Double(c.x), Double(c.y), Double(r1)) else { return }
            addStops(spec.stops, to: pat)
            cairo_set_source(cr, pat)
            cairo_fill(cr)
            cairo_pattern_destroy(pat)
        case .angular(let center, let startAngle, let endAngle):
            let c = center.point(in: rect)
            cairo_save(cr)
            cairo_clip(cr)   // clip to the path (consumes it), then paint wedges over the region
            let radius = Double(hypot(rect.width, rect.height))
            let total = endAngle.radians - startAngle.radians
            let segments = 360
            for i in 0..<segments {
                let f0 = Double(i) / Double(segments), f1 = Double(i + 1) / Double(segments)
                let color = spec.color(at: CGFloat((f0 + f1) / 2))
                cairo_new_path(cr)
                cairo_move_to(cr, Double(c.x), Double(c.y))
                cairo_arc(cr, Double(c.x), Double(c.y), radius, startAngle.radians + total * f0, startAngle.radians + total * f1)
                cairo_close_path(cr)
                cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.opacity)
                cairo_fill(cr)
            }
            cairo_restore(cr)
        }
    }

    private static func addStops(_ stops: [Gradient.Stop], to pattern: OpaquePointer) {
        for stop in stops {
            cairo_pattern_add_color_stop_rgba(pattern, Double(stop.location),
                                              stop.color.red, stop.color.green, stop.color.blue, stop.color.opacity)
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
        gtk4Trace("run: creating GtkApplication")
        let app = hop_app_new("net.hoptools.hopui.demo")!
        self.app = app
        let context = GTK4RunContext(toolkit: self, title: title, onReady: onReady)
        _ = hop_connect_activate(app, gtk4ActivateCallback, Unmanaged.passRetained(context).toOpaque())
        gtk4Trace("run: entering g_application_run (registers on session bus, then fires activate)")
        _ = hop_app_run(app)
        gtk4Trace("run: g_application_run returned (app exited)")
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
        guard signature != toolbarSignature, window != nil else { return }
        toolbarSignature = signature

        // Modern GTK4 toolbar idiom: a GtkHeaderBar installed as the window's titlebar. The bar is created
        // once and shared with the navigation title (which lives in the centered title-widget slot), so a
        // toolbar change must NOT rebuild it — that would drop the title. Remove the prior items, re-pack.
        guard let bar = ensureHeaderBar() else { return }
        for widget in toolbarItemWidgets { hop_header_bar_remove(bar, widget) }
        toolbarItemWidgets = []
        toolbarBoxes = []
        for item in items {
            switch item.kind {
            case .text(let string):
                let label = hop_label_new(string)!
                hop_header_bar_pack_start(bar, label)
                toolbarItemWidgets.append(label)
            case .button(let title, let action):
                let button = hop_button_new(title)!
                let box = GTK4ActionBox()
                box.action = action
                toolbarBoxes.append(box)
                _ = hop_connect_clicked(button, gtk4ClickedCallback, Unmanaged.passUnretained(box).toOpaque())
                hop_header_bar_pack_start(bar, button)
                toolbarItemWidgets.append(button)
            }
        }
    }

    /// GTK renders the navigation bar in native chrome (the header bar's centered title), so
    /// `NavigationStack` publishes the title here rather than as an inline label.
    public var handlesNavigationBarNatively: Bool { true }

    public func setNavigationTitle(_ title: String?) {
        let normalized = (title?.isEmpty == false) ? title : nil
        guard normalized != navigationTitleString else { return }
        navigationTitleString = normalized
        applyNavigationTitle()
    }

    /// Create the window's GtkHeaderBar titlebar once and install it; shared by the toolbar and the
    /// navigation title. Returns nil before the window exists.
    private func ensureHeaderBar() -> UnsafeMutableRawPointer? {
        if let headerBar { return headerBar }
        guard let window else { return nil }
        let bar = hop_header_bar_new()!
        headerBar = bar
        hop_window_set_titlebar(window, bar)
        return bar
    }

    /// Put the navigation title in the header bar's centered title slot (GTK's `.title` style class gives
    /// it the standard header-bar title appearance). A nil title reverts to GTK's default (the window's
    /// own title string); never create an empty header bar just to clear a title.
    private func applyNavigationTitle() {
        if let title = navigationTitleString {
            guard let bar = ensureHeaderBar() else { return }
            let label = hop_label_new(title)!
            hop_widget_add_css_class(label, "title")
            hop_header_bar_set_title_widget(bar, label)
        } else if let headerBar {
            hop_header_bar_set_title_widget(headerBar, nil)
        }
    }
}
