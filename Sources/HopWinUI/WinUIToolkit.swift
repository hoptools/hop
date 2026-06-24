// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import CWinUI
import HopUI
import Foundation

// The WinUI backend implements HopUI's open component system (`WidgetComponent`): a `ComponentRegistry`
// dispatches `realize`/`updateComponent`/`measureComponent`/`didInsertChildren` to per-`WidgetKey`
// renderers (mirroring AppKit/GTK/Qt). This module-private enum is the backend's own creation/behavior
// key — every registered renderer maps its `WidgetKey` onto a `WidgetKind` via `makeNativeWidget`, and the
// handle carries its `kind` so the configure/measure/setFrame/callback paths can dispatch on it. (HopUI's
// public `WidgetKind` enum is gone; this one is internal to HopWinUI.)
enum WidgetKind: Equatable {
    case window, vstack, hstack, label, button, textField, textEditor, slider
    case list, sidebarList, splitView, shape, menu, picker, datePicker, colorPicker
    case separator, progress, spinner, zstack, spacer, scroll, geometry, lazyStack
    case outline, sidebarOutline, image, toggle, secureField, groupBox, tabView
}

// The WinUI 3 toolkit. WinUI/WinRT has no C ABI, so — like HopQt over CQt — this talks to WinUI through the
// CWinUI C++/WinRT shim's pure-C surface (`hopwinui_*`); no WinRT type appears in Swift. Every container is
// a `Canvas` (HopUI's layout engine owns all geometry, placing children absolutely via `setFrame`), and
// leaves map onto TextBlock/Button/TextBox/PasswordBox/ToggleSwitch/Slider/ComboBox/ListView/ProgressBar/
// Image/Shapes.Path/CalendarDatePicker/TimePicker/ColorPicker. `run` owns the Windows App SDK message loop.

/// Opaque handle wrapping a CWinUI element pointer plus the per-widget callbacks the reconciler installs.
/// Mirrors `QtWidget`. The element handle is released on `deinit`.
public final class WinUIWidget {
    // The element pointer, stored as a bit pattern (Sendable) so the nonisolated `deinit` can release it.
    private let handleBits: UInt
    nonisolated var handle: UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: handleBits)! }
    let kind: WidgetKind
    var children: [WinUIWidget] = []
    let isPanel: Bool  // a container children are inserted into

    // Role-derived behavior.
    var flexibleWidth = false
    var isScrollContent = false
    var imageResizable = false
    var imageNaturalSize = CGSize(width: 24, height: 24)

    // Stored callbacks (installed by setAction / set*Handler / configure*).
    var action: (@MainActor () -> Void)?
    var onChangeString: (@MainActor (String) -> Void)?
    var onSubmit: (@MainActor () -> Void)?
    var onChangeDouble: (@MainActor (Double) -> Void)?
    var onChangeBool: (@MainActor (Bool) -> Void)?
    var onSelectIndex: (@MainActor (Int?) -> Void)?
    var pickerOnSelect: (@MainActor (Int) -> Void)?
    var outlineOnSelect: (@MainActor (AnyHashable?) -> Void)?
    var tabOnSelect: (@MainActor (Int) -> Void)?
    var scrollHandler: (@MainActor (CGSize) -> Void)?
    var onChangeDate: (@MainActor (Date) -> Void)?
    var onChangeColor: (@MainActor (HopUI.Color) -> Void)?
    var tapAction: (@MainActor () -> Void)?   // `.onTapGesture`
    var tapConnected = false                  // the Tapped/DoubleTapped event is wired at most once
    // Newer pointer gestures — handler stored on the handle; the event is wired at most once (like tap).
    var longPressAction: (@MainActor () -> Void)?
    var longPressConnected = false
    var onHoverHandler: (@MainActor (Bool) -> Void)?
    var hoverConnected = false
    var dragChanged: (@MainActor (DragGesture.Value) -> Void)?
    var dragEnded: (@MainActor (DragGesture.Value) -> Void)?
    var dragConnected = false
    // Magnify + rotate both come from one ManipulationDelta stream (cumulative scale + rotation), wired once.
    var magnifyChanged: (@MainActor (MagnifyGesture.Value) -> Void)?
    var magnifyEnded: (@MainActor (MagnifyGesture.Value) -> Void)?
    var rotateChanged: (@MainActor (RotateGesture.Value) -> Void)?
    var rotateEnded: (@MainActor (RotateGesture.Value) -> Void)?
    var manipConnected = false

    /// Suppresses change callbacks while reflecting a bound value programmatically.
    var suppress = false

    // Caches.
    var lastValue: String?
    // Modal-presentation state (`.alert` / `.sheet`).
    var alertPresenting = false
    var sheetPresenting = false
    var sheetDialog: UnsafeMutableRawPointer?
    var sheetReconciler: Reconciler<WinUIToolkit>?
    // `.disabled` state set on this node (nil = not specified). Stashed so `didInsertChildren` can re-cascade
    // a container's disable to children that are inserted after `configure` ran.
    var enabledState: Bool?
    var listCount = -1
    var pickerOptions: [String] = []
    // Which native form a `.picker` took. The ComboBox / segmented button-group / inline ListView each
    // render very differently and their WinRT `DesiredSize` is unreliable (a ComboBox reports its dropped-
    // down items' height; un-templated ToggleButtons report only text height), so `measure` returns an
    // explicit size per style instead of trusting the measurement. nil for non-picker widgets.
    enum PickerRender { case combo, segmented, radio, inline }
    var pickerRender: PickerRender?
    var outlineSignature: String?
    var outlineKeyByRow: [String] = []
    var outlineIDByKey: [String: AnyHashable] = [:]

    // `.shape` spec, redrawn on every `setFrame`.
    var shapeSpec: ShapeSpec?
    // `.datePicker`: a row hosting a date + a time control (which the bound components show/hide); `dpDate`
    // merges a partial (date-only / time-only) edit back with the other component.
    var datePart: UnsafeMutableRawPointer?
    var timePart: UnsafeMutableRawPointer?
    var dpDate = Date(timeIntervalSince1970: 0)
    // `.tabView`: the tab-button strip + retained per-button index boxes.
    var tabStrip: WinUIWidget?
    var tabSelected = 0
    var tabButtonBoxes: [TabButtonBox] = []
    // Retained menu-item action boxes (rebuilt each configureMenu) so their C callbacks stay valid.
    var menuBoxes: [MenuActionBox] = []
    // Size stamped by `setFrame` for native panes (read by `sizeOf`).
    var stampedSize: CGSize?

    init(_ handle: UnsafeMutableRawPointer, kind: WidgetKind, isPanel: Bool = false) {
        self.handleBits = UInt(bitPattern: handle)
        self.kind = kind
        self.isPanel = isPanel
    }
    // WinUI elements live on the UI thread, so deinitialize there — and `isolated deinit` lets us release
    // the element handle and the main-actor-isolated stored properties (tabStrip, callbacks, …) safely.
    isolated deinit { hopwinui_release(handle) }
}

/// Per-tab-button context so a tab button's click reports its index. Retained by the tab-view widget.
public final class TabButtonBox {
    unowned let owner: WinUIWidget
    let index: Int
    init(_ owner: WinUIWidget, _ index: Int) { self.owner = owner; self.index = index }
}

// Non-capturing C callbacks; the widget arrives via `user_data` (Unmanaged). The shim fires these on the UI
// thread, so asserting main-actor isolation to touch HopUI state is sound.
private func widget(_ ud: UnsafeMutableRawPointer?) -> WinUIWidget? {
    guard let ud else { return nil }
    return Unmanaged<WinUIWidget>.fromOpaque(ud).takeUnretainedValue()
}

private let cbAction: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { if !w.suppress { w.action?() } }
}
private let cbTap: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { w.tapAction?() }
}
private let cbLongPress: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { w.longPressAction?() }
}
// TextBox/PasswordBox Enter key → `.onSubmit`.
private let cbSubmit: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { w.onSubmit?() }
}
private let cbHover: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ud, entered in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { w.onHoverHandler?(entered != 0) }
}
private let cbDrag: @convention(c) (UnsafeMutableRawPointer?, Double, Double, Double, Double, Int32) -> Void = { ud, sx, sy, cx, cy, ended in
    guard let w = widget(ud) else { return }
    let value = DragGesture.Value(startLocation: CGPoint(x: sx, y: sy),
                                  location: CGPoint(x: cx, y: cy),
                                  translation: CGSize(width: cx - sx, height: cy - sy))
    MainActor.assumeIsolated { if ended != 0 { w.dragEnded?(value) } else { w.dragChanged?(value) } }
}
// One ManipulationDelta stream carries cumulative scale + rotation (degrees). We fan it out to both the
// magnify and rotate handlers; the inactive axis reports identity (scale 1.0 / rotation 0), which is a no-op.
private let cbManip: @convention(c) (UnsafeMutableRawPointer?, Double, Double, Int32) -> Void = { ud, cumScale, cumRotationDegrees, ended in
    guard let w = widget(ud) else { return }
    let mag = MagnifyGesture.Value(magnification: CGFloat(cumScale))
    let rot = RotateGesture.Value(rotation: Angle(degrees: cumRotationDegrees))
    MainActor.assumeIsolated {
        if ended != 0 { w.magnifyEnded?(mag); w.rotateEnded?(rot) }
        else { w.magnifyChanged?(mag); w.rotateChanged?(rot) }
    }
}
private let cbString: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { s, ud in
    guard let w = widget(ud), let s else { return }
    let value = String(cString: s)
    // Track the widget's live text so configure's `value != lastValue` guard reflects reality after a user
    // edit — otherwise lastValue goes stale and the next reconcile re-sets the same text, resetting the caret.
    MainActor.assumeIsolated { if !w.suppress { w.lastValue = value; w.onChangeString?(value) } }
}
private let cbDouble: @convention(c) (Double, UnsafeMutableRawPointer?) -> Void = { v, ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { if !w.suppress { w.onChangeDouble?(v) } }
}
private let cbBool: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { v, ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { if !w.suppress { w.onChangeBool?(v != 0) } }
}
private let cbListSelect: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { v, ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated {
        guard !w.suppress else { return }
        let i = Int(v)
        if w.kind == .outline || w.kind == .sidebarOutline {
            let id = (i >= 0 && i < w.outlineKeyByRow.count) ? w.outlineIDByKey[w.outlineKeyByRow[i]] : nil
            w.outlineOnSelect?(id)
        } else {
            w.onSelectIndex?(i >= 0 ? i : nil)
        }
    }
}
private let cbComboSelect: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { v, ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { if !w.suppress, v >= 0 { w.pickerOnSelect?(Int(v)) } }
}
private let cbScroll: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = { x, y, ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { w.scrollHandler?(CGSize(width: x, height: y)) }
}
private let cbColor: @convention(c) (Double, Double, Double, Double, UnsafeMutableRawPointer?) -> Void = { r, g, b, a, ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated { if !w.suppress { w.onChangeColor?(HopUI.Color(red: r, green: g, blue: b, opacity: a)) } }
}
// CalendarDatePicker fires with seconds-since-1970 (midnight of the picked day); merge with the kept time.
private let cbDate: @convention(c) (Double, UnsafeMutableRawPointer?) -> Void = { secs, ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated {
        guard !w.suppress else { return }
        let merged = WinUIToolkit.compose(day: Date(timeIntervalSince1970: secs), secondsIntoDay: WinUIToolkit.timeOfDay(w.dpDate))
        w.dpDate = merged
        w.onChangeDate?(merged)
    }
}
// TimePicker fires with seconds-of-day; merge with the kept day.
private let cbTime: @convention(c) (Double, UnsafeMutableRawPointer?) -> Void = { secs, ud in
    guard let w = widget(ud) else { return }
    MainActor.assumeIsolated {
        guard !w.suppress else { return }
        let merged = WinUIToolkit.compose(day: w.dpDate, secondsIntoDay: secs)
        w.dpDate = merged
        w.onChangeDate?(merged)
    }
}
private let cbTabButton: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
    guard let ud else { return }
    let box = Unmanaged<TabButtonBox>.fromOpaque(ud).takeUnretainedValue()
    MainActor.assumeIsolated { box.owner.tabOnSelect?(box.index) }
}
private let cbReady: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { root, ud in
    guard let root, let ud else { return }
    let rootBits = UInt(bitPattern: root)  // cross a Sendable value into the main-actor closure
    let toolkit = Unmanaged<WinUIToolkit>.fromOpaque(ud).takeUnretainedValue()
    MainActor.assumeIsolated { toolkit.handleReady(UnsafeMutableRawPointer(bitPattern: rootBits)!) }
}
private let cbRelayout: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
    guard let ud else { return }
    let toolkit = Unmanaged<WinUIToolkit>.fromOpaque(ud).takeUnretainedValue()
    MainActor.assumeIsolated { toolkit.relayoutHandler?() }
}
private let cbScheduleWork: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
    guard let ud else { return }
    Unmanaged<ScheduledWork>.fromOpaque(ud).takeRetainedValue().run()
}

/// Boxes a `@MainActor` closure for `scheduleOnMainThread`'s C callback.
final class ScheduledWork {
    let work: @MainActor () -> Void
    init(_ work: @escaping @MainActor () -> Void) { self.work = work }
    func run() { MainActor.assumeIsolated { work() } }
}

public final class WinUIToolkit: AppToolkit {
    public typealias Handle = WinUIWidget

    private var onReadyClosure: (@MainActor (WinUIWidget) -> Void)?
    var relayoutHandler: (@MainActor () -> Void)?

    // MARK: - Open component system (the extensibility seam)

    public static let toolkitID = ToolkitID.winUI
    public let components = ComponentRegistry<WinUIWidget>()

    public init() { registerBuiltinComponents() }

    public func realize(_ component: any WidgetComponent) -> WinUIWidget {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.make(component) }
        if let ptr = component.makeNative(Self.toolkitID) as? UnsafeMutableRawPointer {
            // A self-hosted widget (e.g. HopUIComboBox's editable ComboBox) is a control that should fill the
            // width it's given — otherwise its WinRT DesiredSize.Width (often just its glyph/min width) is what
            // `.frame(width:)` lays out, collapsing the control. Mark it flexibleWidth so `measure` reports the
            // proposed width, mirroring AppKit (which treats an editable NSTextField/NSComboBox as fill-width).
            let widget = WinUIWidget(ptr, kind: .vstack)
            widget.flexibleWidth = true
            return widget
        }
        assertionFailure("HopUI/WinUI: no renderer registered for WidgetKey \"\(component.widgetKey.rawValue)\", and the component self-hosts no native element")
        return makeWidget(.vstack)
    }

    public func updateComponent(_ handle: WinUIWidget, _ component: any WidgetComponent) {
        if let renderer = components.renderer(for: component.widgetKey) { renderer.update(handle, component); return }
        component.updateNative(handle.handle, Self.toolkitID)
    }

    public func measureComponent(_ handle: WinUIWidget, _ component: any WidgetComponent, _ proposal: ProposedViewSize) -> CGSize {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.measure(handle, component, proposal) }
        switch component.role {
        case .fill, .native: return proposal.resolved(.zero)
        default: return measure(handle, proposal)
        }
    }

    public func didInsertChildren(_ handle: WinUIWidget, _ component: any WidgetComponent) {
        // A container with `.disabled(true)` must cascade to the controls within it, but `configure` ran in
        // `realize` *before* the children were inserted — so re-apply the disable now that the subtree exists
        // (this hook fires after children are inserted/reconciled, on both mount and update). Only re-apply
        // *disable*, never force-enable, so a descendant's own `.disabled` is preserved — matching SwiftUI's
        // rule that an ancestor's disable can't be re-enabled by a descendant.
        if handle.enabledState == false { hopwinui_set_enabled(handle.handle, 0) }
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

    /// Simple leaves (Text/Button/TextField/SecureField/Slider/Toggle/ProgressView/Divider): a native
    /// widget + a ``WidgetPatch`` + optional change handlers, all carried by ``PrimitiveLeafComponent``.
    private func registerLeafComponents() {
        let leaves: [WidgetKey] = [.label, .button, .textField, .secureField, .textEditor, .slider, .progress, .spinner, .separator]
            + ToggleStyle.allCases.map { .toggle($0) }   // toggle.switch / .checkbox / .button / .automatic
        for key in leaves {
            components.register(.init(
                make: { [unowned self] component in let h = makeNativeWidget(key); applyLeaf(h, component); return h },
                update: { [unowned self] h, component in applyLeaf(h, component) },
                measure: { [unowned self] h, _, proposal in measure(h, proposal) }
            ), for: key)
        }
    }

    private func applyLeaf(_ handle: WinUIWidget, _ component: any WidgetComponent) {
        guard let leaf = component as? PrimitiveLeafComponent else { return }
        configure(handle, leaf.patch)
        handle.action = leaf.action
        handle.onChangeString = leaf.onChange
        handle.onChangeDouble = leaf.onChangeDouble
        handle.onChangeBool = leaf.onChangeBool
    }

    /// Leaves carrying a richer spec (DatePicker/ColorPicker/Menu/Shape) — same shape as a leaf, but the
    /// component's spec drives a dedicated configure step.
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

    /// Layout containers (VStack/HStack/ZStack/GroupBox + the framework's scroll/geometry/lazyStack/spacer
    /// wrappers): just the empty native Canvas/ScrollViewer — the layout engine arranges children from `role`.
    private func registerContainerComponents() {
        let containers: [WidgetKey] = [.vstack, .hstack, .zstack, .groupBox, .scroll, .geometry, .lazyStack, .spacer,
                                       .grid, .gridRow]
        for key in containers {
            components.register(.init(
                make: { [unowned self] _ in makeNativeWidget(key) },
                update: { _, _ in },
                measure: { [unowned self] h, _, p in measure(h, p) }
            ), for: key)
        }
    }

    /// Native composites (role `.native`): List/Outline (flat + sidebar), NavigationSplitView, TabView. The
    /// TabView builds its tab strip in `afterChildren`, once its pages have been inserted.
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

    private func registerImageComponent() {
        components.register(.init(
            make: { [unowned self] c in let h = makeNativeWidget(.image); if let s = (c as? ImageComponent)?.spec { configureImage(h, s) }; return h },
            update: { [unowned self] h, c in if let s = (c as? ImageComponent)?.spec { configureImage(h, s) } },
            measure: { [unowned self] h, _, p in measure(h, p) }
        ), for: .image)
    }

    /// `Picker` renderers — each style is a distinct native widget under its own key. `.menu`/`.automatic`
    /// → ComboBox; `.segmented` → a horizontal row of ToggleButtons; `.radioGroup` → a column of
    /// RadioButtons. The reconciler recreates the widget when the style changes.
    private func registerPickerComponents() {
        let combo = ComponentRegistry<WinUIWidget>.Renderer(
            make: { [unowned self] c in let h = makeWidget(.picker); h.pickerRender = .combo; if let s = (c as? PickerComponent)?.spec { configurePicker(h, s) }; return h },
            update: { [unowned self] h, c in if let s = (c as? PickerComponent)?.spec { configurePicker(h, s) } },
            measure: { [unowned self] h, _, p in measure(h, p) })
        components.register(combo, for: .picker(.menu))
        components.register(combo, for: .picker(.automatic))

        for (style, horizontal, toggle) in [(PickerStyle.segmented, true, true), (PickerStyle.radioGroup, false, false)] {
            components.register(.init(
                make: { [unowned self] c in
                    let w = WinUIWidget(hopwinui_buttongroup_new(horizontal ? 1 : 0), kind: .picker)
                    w.pickerRender = horizontal ? .segmented : .radio
                    if let s = (c as? PickerComponent)?.spec { configureButtonGroupPicker(w, s, toggle: toggle) }
                    return w
                },
                update: { [unowned self] h, c in if let s = (c as? PickerComponent)?.spec { configureButtonGroupPicker(h, s, toggle: toggle) } },
                measure: { [unowned self] h, _, p in measure(h, p) }
            ), for: .picker(style))
        }

        // .inline → a ListView (every option a selectable row). Reuses the List shims, but wires
        // cbComboSelect so the SelectionChanged routes to `pickerOnSelect` (cbListSelect routes to a List's
        // onSelectIndex instead).
        components.register(.init(
            make: { [unowned self] c in
                let w = WinUIWidget(hopwinui_listview_new(), kind: .picker)
                w.pickerRender = .inline
                hopwinui_listview_connect(w.handle, cbComboSelect, unmanaged(w))
                if let s = (c as? PickerComponent)?.spec { configureInlinePicker(w, s) }
                return w
            },
            update: { [unowned self] h, c in if let s = (c as? PickerComponent)?.spec { configureInlinePicker(h, s) } },
            measure: { [unowned self] h, _, p in measure(h, p) }
        ), for: .picker(.inline))
    }

    /// Configure the inline picker: (re)populate the ListView when options change, otherwise reflect the
    /// bound selection. Mirrors `configurePicker` but backed by the ListView shims.
    public func configureInlinePicker(_ handle: WinUIWidget, _ spec: PickerSpec) {
        handle.pickerOnSelect = spec.onSelect
        if handle.pickerOptions != spec.options {
            handle.pickerOptions = spec.options
            handle.suppress = true
            withCStrings(spec.options) { hopwinui_listview_set_items(handle.handle, $0, Int32(spec.options.count)) }
            handle.suppress = false
        }
        let target = Int32(spec.selectedIndex ?? -1)
        if hopwinui_listview_selected(handle.handle) != target {
            handle.suppress = true
            hopwinui_listview_set_selected(handle.handle, target)
            handle.suppress = false
        }
    }

    /// Configure a segmented / radio-group picker: (re)populate when the options change, otherwise reflect
    /// the bound selection. `toggle` selects ToggleButtons (segmented) vs RadioButtons (radio).
    public func configureButtonGroupPicker(_ handle: WinUIWidget, _ spec: PickerSpec, toggle: Bool) {
        handle.pickerOnSelect = spec.onSelect
        if handle.pickerOptions != spec.options {
            handle.pickerOptions = spec.options
            handle.suppress = true
            withCStrings(spec.options) {
                hopwinui_buttongroup_set_items(handle.handle, $0, Int32(spec.options.count),
                                               Int32(spec.selectedIndex ?? -1), toggle ? 1 : 0, cbComboSelect, unmanaged(handle))
            }
            handle.suppress = false
        } else {
            handle.suppress = true
            hopwinui_buttongroup_set_selected(handle.handle, Int32(spec.selectedIndex ?? -1))
            handle.suppress = false
        }
    }

    // MARK: - Widget creation

    /// Create the native element for a built-in ``WidgetKey`` (registered renderers call this with the keys
    /// the switch knows; picker styles route through `.picker`).
    private func makeNativeWidget(_ key: WidgetKey) -> WinUIWidget {
        // Toggle styles ("toggle.<style>") pick a distinct native control; the style is lost by `kind(for:)`
        // (all toggles share `.toggle`), so resolve it here. Idiomatic: switch=ToggleSwitch, checkbox=CheckBox,
        // button=ToggleButton — all driven through the same `.toggle` configure path.
        if key.rawValue.hasPrefix("toggle.") {
            let style = ToggleStyle(rawValue: String(key.rawValue.dropFirst("toggle.".count))) ?? .automatic
            let ptr: UnsafeMutableRawPointer
            switch style {
            case .checkbox: ptr = hopwinui_checkbox_new()
            case .button: ptr = hopwinui_togglebutton_new()
            case .switch, .automatic: ptr = hopwinui_toggleswitch_new()
            }
            let w = WinUIWidget(ptr, kind: .toggle)
            hopwinui_toggle_connect(w.handle, cbBool, unmanaged(w))
            return w
        }
        return makeWidget(kind(for: key))
    }

    private func kind(for key: WidgetKey) -> WidgetKind {
        switch key {
        case .window: return .window
        case .vstack: return .vstack
        case .hstack: return .hstack
        case .zstack: return .zstack
        case .spacer: return .spacer
        case .scroll: return .scroll
        case .geometry: return .geometry
        case .lazyStack: return .lazyStack
        // Grid/GridRow are plain absolute-positioning canvas panels (like a stack); the shared layout
        // engine positions their cells from `role`, so they reuse the `.vstack` canvas-panel widget kind.
        case .grid, .gridRow: return .vstack
        case .groupBox: return .groupBox
        case .label: return .label
        case .button: return .button
        case .textField: return .textField
        case .textEditor: return .textEditor
        case .secureField: return .secureField
        case .slider: return .slider
        case .toggle: return .toggle
        case .progress: return .progress
        case .spinner: return .spinner
        case .separator: return .separator
        case .shape: return .shape
        case .menu: return .menu
        case .datePicker: return .datePicker
        case .colorPicker: return .colorPicker
        case .image: return .image
        case .list: return .list
        case .sidebarList: return .sidebarList
        case .outline: return .outline
        case .sidebarOutline: return .sidebarOutline
        case .splitView: return .splitView
        case .tabView: return .tabView
        default: return .picker  // picker styles ("picker.<style>") and any unknown key
        }
    }

    func makeWidget(_ kind: WidgetKind) -> WinUIWidget {
        switch kind {
        case .vstack, .hstack, .zstack, .spacer, .geometry, .lazyStack, .window, .splitView, .tabView:
            return WinUIWidget(hopwinui_canvas_new(), kind: kind, isPanel: true)
        case .groupBox:
            let w = WinUIWidget(hopwinui_canvas_new(), kind: kind, isPanel: true)
            hopwinui_set_background(w.handle, 0.5, 0.5, 0.5, 0.10)
            return w
        case .scroll:
            let w = WinUIWidget(hopwinui_scrollviewer_new(), kind: kind)
            hopwinui_scrollviewer_connect(w.handle, cbScroll, unmanaged(w))
            return w
        case .label:
            return WinUIWidget(hopwinui_textblock_new(), kind: kind)
        case .button:
            let w = WinUIWidget(hopwinui_button_new(), kind: kind)
            hopwinui_button_connect(w.handle, cbAction, unmanaged(w))
            return w
        case .textField:
            let w = WinUIWidget(hopwinui_textbox_new(), kind: kind); w.flexibleWidth = true
            hopwinui_textbox_connect(w.handle, cbString, unmanaged(w))
            hopwinui_textbox_connect_submit(w.handle, cbSubmit, unmanaged(w))
            return w
        case .textEditor:
            // A multiline TextBox (AcceptsReturn + Wrap + vertical scrollbar) — fills its frame (role .fill).
            let w = WinUIWidget(hopwinui_textbox_new(), kind: kind)
            hopwinui_textbox_set_multiline(w.handle, 1)
            hopwinui_textbox_connect(w.handle, cbString, unmanaged(w))
            return w
        case .secureField:
            let w = WinUIWidget(hopwinui_passwordbox_new(), kind: kind); w.flexibleWidth = true
            hopwinui_passwordbox_connect(w.handle, cbString, unmanaged(w))
            hopwinui_textbox_connect_submit(w.handle, cbSubmit, unmanaged(w))
            return w
        case .toggle:
            let w = WinUIWidget(hopwinui_toggleswitch_new(), kind: kind)
            hopwinui_toggle_connect(w.handle, cbBool, unmanaged(w))
            return w
        case .slider:
            let w = WinUIWidget(hopwinui_slider_new(), kind: kind); w.flexibleWidth = true
            hopwinui_slider_connect(w.handle, cbDouble, unmanaged(w))
            return w
        case .list, .sidebarList, .outline, .sidebarOutline:
            let w = WinUIWidget(hopwinui_listview_new(), kind: kind)
            hopwinui_listview_connect(w.handle, cbListSelect, unmanaged(w))
            return w
        case .shape:
            return WinUIWidget(hopwinui_path_new(), kind: kind)
        case .image:
            return WinUIWidget(hopwinui_image_new(), kind: kind)
        case .menu:
            return WinUIWidget(hopwinui_menubutton_new(), kind: kind)
        case .picker:
            let w = WinUIWidget(hopwinui_combobox_new(), kind: kind)
            hopwinui_combobox_connect(w.handle, cbComboSelect, unmanaged(w))
            return w
        case .separator:
            let w = WinUIWidget(hopwinui_border_new(), kind: kind)
            hopwinui_set_background(w.handle, 0.5, 0.5, 0.5, 0.4)
            return w
        case .progress:
            let w = WinUIWidget(hopwinui_progressbar_new(), kind: kind); w.flexibleWidth = true
            return w
        case .spinner:
            // Indeterminate → a circular ProgressRing (self-animating); fixed square, not a fill-width bar.
            return WinUIWidget(hopwinui_progressring_new(), kind: kind)
        case .datePicker:
            // A row hosting a CalendarDatePicker (min-width 240) + a TimePicker (min-width 150); both are
            // shown/hidden by configureDatePicker per the bound components.
            let w = WinUIWidget(hopwinui_stackpanel_new(0), kind: kind, isPanel: true)
            let date = hopwinui_calendardatepicker_new()!
            let time = hopwinui_timepicker_new()!
            hopwinui_set_min_width(date, 240); hopwinui_set_min_width(time, 150)
            hopwinui_panel_insert(w.handle, date, 0)
            hopwinui_panel_insert(w.handle, time, 1)
            w.datePart = date; w.timePart = time
            hopwinui_datepicker_connect(date, cbDate, unmanaged(w))
            hopwinui_timepicker_connect(time, cbTime, unmanaged(w))
            return w
        case .colorPicker:
            let w = WinUIWidget(hopwinui_colorpicker_new(), kind: kind)
            hopwinui_colorpicker_connect(w.handle, cbColor, unmanaged(w))
            return w
        }
    }

    private func unmanaged(_ w: WinUIWidget) -> UnsafeMutableRawPointer { Unmanaged.passUnretained(w).toOpaque() }

    // MARK: - Configuration

    public func configure(_ handle: WinUIWidget, _ patch: WidgetPatch) {
        let h = handle.handle
        switch handle.kind {
        case .label:
            if let text = patch.text { hopwinui_textblock_set_text(h, text) }
            if let fg = patch.foregroundColor { hopwinui_textblock_set_foreground(h, fg.red, fg.green, fg.blue, fg.opacity) }
            if let align = patch.textAlignment {
                hopwinui_textblock_set_alignment(h, align == .leading ? 0 : align == .center ? 1 : 2)
            }
            if patch.font != nil || patch.fontWeight != nil || patch.italic != nil || patch.monospaced != nil {
                let font = patch.font
                let weight = patch.fontWeight ?? font?.weight
                // `.monospaced` → Consolas (universally available on Windows).
                let family = (patch.monospaced == true) ? "Consolas" : (font?.family ?? "")
                hopwinui_textblock_set_font(h, font?.size ?? 0, family, Int32(weight?.cssValue ?? 0), (patch.italic == true) ? 1 : 0)
            }
        case .button:
            if let title = patch.title { hopwinui_button_set_text(h, title) }
        case .textField:
            if let placeholder = patch.placeholder { hopwinui_textbox_set_placeholder(h, placeholder) }
            if let value = patch.value, value != handle.lastValue {
                handle.lastValue = value; handle.suppress = true; hopwinui_textbox_set_text(h, value); handle.suppress = false
            }
        case .textEditor:   // multiline TextBox — same value reflection as the text field (no placeholder)
            if let value = patch.value, value != handle.lastValue {
                handle.lastValue = value; handle.suppress = true; hopwinui_textbox_set_text(h, value); handle.suppress = false
            }
        case .secureField:
            if let placeholder = patch.placeholder { hopwinui_passwordbox_set_placeholder(h, placeholder) }
            if let value = patch.value, value != handle.lastValue {
                handle.lastValue = value; handle.suppress = true; hopwinui_passwordbox_set_text(h, value); handle.suppress = false
            }
        case .slider:
            if let minV = patch.minValue, let maxV = patch.maxValue { hopwinui_slider_set_range(h, minV, maxV) }
            if let v = patch.doubleValue, abs(hopwinui_slider_value(h) - v) > 0.0001 {
                handle.suppress = true; hopwinui_slider_set_value(h, v); handle.suppress = false
            }
        case .toggle:
            if let title = patch.title { hopwinui_toggle_set_label(h, title) }  // checkbox/button carry their own label
            if let on = patch.boolValue, (hopwinui_toggle_is_on(h) != 0) != on {
                handle.suppress = true; hopwinui_toggle_set_on(h, on ? 1 : 0); handle.suppress = false
            }
        case .progress:
            if let value = patch.progressValue { hopwinui_progress_set_value(h, value) } else { hopwinui_progress_set_indeterminate(h) }
        default:
            break
        }
        if let bg = patch.backgroundColor { hopwinui_set_background(h, bg.red, bg.green, bg.blue, bg.opacity) }
        if let label = patch.accessibilityLabel { hopwinui_set_automation_name(h, label) }
        if let identifier = patch.accessibilityIdentifier { hopwinui_set_automation_id(h, identifier) }
        // `.opacity` (UIElement.Opacity composites the subtree) and `.disabled` (Control.IsEnabled, which the
        // shim cascades through descendant Controls since a Canvas container isn't itself a Control). The state
        // is also stashed so `didInsertChildren` can re-cascade it once a disabled container's children exist.
        hopwinui_set_opacity(h, patch.opacity ?? 1)
        if let enabled = patch.isEnabled { handle.enabledState = enabled; hopwinui_set_enabled(h, enabled ? 1 : 0) }
    }

    // MARK: - Tree mutation

    public func insert(_ child: WinUIWidget, into parent: WinUIWidget, at index: Int) {
        if parent.kind == .scroll {
            child.isScrollContent = true
            hopwinui_scrollviewer_set_content(parent.handle, child.handle)
            parent.children = [child]
            return
        }
        guard parent.isPanel else { return }
        let clamped = max(0, min(index, parent.children.count))
        hopwinui_panel_insert(parent.handle, child.handle, Int32(clamped))
        parent.children.insert(child, at: clamped)
    }

    public func move(_ child: WinUIWidget, in parent: WinUIWidget, to index: Int) {
        guard parent.isPanel, let from = parent.children.firstIndex(where: { $0 === child }) else { return }
        hopwinui_panel_move(parent.handle, child.handle, Int32(index))
        parent.children.remove(at: from)
        parent.children.insert(child, at: max(0, min(index, parent.children.count)))
    }

    public func remove(_ child: WinUIWidget, from parent: WinUIWidget) {
        if parent.kind == .scroll { parent.children.removeAll { $0 === child }; return }
        guard parent.isPanel, let idx = parent.children.firstIndex(where: { $0 === child }) else { return }
        hopwinui_panel_remove(parent.handle, child.handle)
        parent.children.remove(at: idx)
    }

    public func setScrollHandler(_ handle: WinUIWidget, _ handler: (@MainActor (CGSize) -> Void)?) { handle.scrollHandler = handler }

    public func setTapHandler(_ handle: WinUIWidget, _ spec: TapGestureSpec?) {
        handle.tapAction = spec?.action
        // Wire the Tapped/DoubleTapped event once; later reconciles just update tapAction (a nil action
        // makes the wired handler a no-op, so we never need to detach).
        if let spec, !handle.tapConnected {
            hopwinui_tap_connect(handle.handle, Int32(Swift.max(1, spec.count)), cbTap, unmanaged(handle))
            handle.tapConnected = true
        }
    }

    public func setLongPressHandler(_ handle: WinUIWidget, _ spec: LongPressGestureSpec?) {
        handle.longPressAction = spec?.action
        if spec != nil, !handle.longPressConnected {
            hopwinui_longpress_connect(handle.handle, cbLongPress, unmanaged(handle))
            handle.longPressConnected = true
        }
    }

    public func setHoverHandler(_ handle: WinUIWidget, _ handler: (@MainActor (Bool) -> Void)?) {
        handle.onHoverHandler = handler
        if handler != nil, !handle.hoverConnected {
            hopwinui_hover_connect(handle.handle, cbHover, unmanaged(handle))
            handle.hoverConnected = true
        }
    }

    public func setDragHandler(_ handle: WinUIWidget, _ spec: DragGestureSpec?) {
        handle.dragChanged = spec?.onChanged
        handle.dragEnded = spec?.onEnded
        if spec != nil, !handle.dragConnected {
            hopwinui_drag_connect(handle.handle, cbDrag, unmanaged(handle))
            handle.dragConnected = true
        }
    }

    public func setSubmitHandler(_ handle: WinUIWidget, _ handler: (@MainActor () -> Void)?) {
        handle.onSubmit = handler   // the TextBox/PasswordBox Enter handler is wired once at creation
    }

    public func setMagnifyHandler(_ handle: WinUIWidget, _ spec: MagnifyGestureSpec?) {
        handle.magnifyChanged = spec?.onChanged
        handle.magnifyEnded = spec?.onEnded
        ensureManipConnected(handle)
    }

    public func setRotateHandler(_ handle: WinUIWidget, _ spec: RotateGestureSpec?) {
        handle.rotateChanged = spec?.onChanged
        handle.rotateEnded = spec?.onEnded
        ensureManipConnected(handle)
    }

    /// Wire the element's ManipulationMode + ManipulationDelta once (it feeds both magnify and rotate).
    /// Like drag, it stays connected for the element's lifetime; clearing a handler just nils the closure.
    private func ensureManipConnected(_ handle: WinUIWidget) {
        let wanted = handle.magnifyChanged != nil || handle.magnifyEnded != nil
            || handle.rotateChanged != nil || handle.rotateEnded != nil
        guard wanted, !handle.manipConnected else { return }
        hopwinui_manip_connect(handle.handle, cbManip, unmanaged(handle))
        handle.manipConnected = true
    }

    // MARK: - Composite configuration

    public func configureList(_ handle: WinUIWidget, _ spec: ListSpec) {
        handle.onSelectIndex = spec.onSelect
        if handle.listCount != spec.count {
            handle.listCount = spec.count
            let rows = (0 ..< spec.count).map { spec.rowText($0) }
            withCStrings(rows) { hopwinui_listview_set_items(handle.handle, $0, Int32(spec.count)) }
        }
        let target = Int32(spec.selectedIndex ?? -1)
        if hopwinui_listview_selected(handle.handle) != target {
            handle.suppress = true; hopwinui_listview_set_selected(handle.handle, target); handle.suppress = false
        }
    }

    public func configureOutline(_ handle: WinUIWidget, _ spec: OutlineSpec) {
        handle.outlineOnSelect = spec.onSelect
        let signature = spec.structureSignature
        if handle.outlineSignature != signature {
            handle.outlineSignature = signature
            let flat = spec.flattened()
            handle.outlineKeyByRow = flat.map { $0.node.key }
            handle.outlineIDByKey = Dictionary(flat.map { ($0.node.key, $0.node.id) }, uniquingKeysWith: { a, _ in a })
            let rows = flat.map { String(repeating: "    ", count: $0.depth) + $0.node.title }
            withCStrings(rows) { hopwinui_listview_set_items(handle.handle, $0, Int32(rows.count)) }
        }
        let targetKey = spec.selectedID.map { "\($0.base)" }
        let target = Int32(targetKey.flatMap { handle.outlineKeyByRow.firstIndex(of: $0) } ?? -1)
        if hopwinui_listview_selected(handle.handle) != target {
            handle.suppress = true; hopwinui_listview_set_selected(handle.handle, target); handle.suppress = false
        }
    }

    public func configurePicker(_ handle: WinUIWidget, _ spec: PickerSpec) {
        handle.pickerOnSelect = spec.onSelect
        if handle.pickerOptions != spec.options {
            handle.pickerOptions = spec.options
            withCStrings(spec.options) { hopwinui_combobox_set_items(handle.handle, $0, Int32(spec.options.count)) }
        }
        let target = Int32(spec.selectedIndex ?? -1)
        if hopwinui_combobox_selected(handle.handle) != target {
            handle.suppress = true; hopwinui_combobox_set_selected(handle.handle, target); handle.suppress = false
        }
    }

    public func configureMenu(_ handle: WinUIWidget, _ menu: MenuContent) {
        hopwinui_menubutton_set_label(handle.handle, menu.label)
        guard let flyout = hopwinui_menubutton_flyout(handle.handle) else { return }
        hopwinui_menu_clear(flyout)
        handle.menuBoxes.removeAll()
        buildMenu(menu.entries, into: flyout, owner: handle)
    }

    private func buildMenu(_ entries: [MenuEntry], into container: UnsafeMutableRawPointer, owner: WinUIWidget) {
        for entry in entries {
            switch entry {
            case .separator:
                hopwinui_menu_add_separator(container)
            case .button(let title, let action):
                let box = MenuActionBox(action)
                owner.menuBoxes.append(box)
                hopwinui_menu_add_item(container, title, cbMenuItem, Unmanaged.passUnretained(box).toOpaque())
            case .submenu(let title, let subEntries):
                if let sub = hopwinui_menu_add_submenu(container, title) {
                    buildMenu(subEntries, into: sub, owner: owner)
                }
            }
        }
    }

    public func configureShape(_ handle: WinUIWidget, _ spec: ShapeSpec) {
        handle.shapeSpec = spec
        if let size = handle.stampedSize { redrawShape(handle, CGRect(origin: .zero, size: size)) }
    }

    public func configureImage(_ handle: WinUIWidget, _ spec: ImageSpec) {
        handle.imageResizable = spec.resizable
        switch spec.source {
        case .file, .named:
            if let url = spec.resolvedURL() { hopwinui_image_set_file(handle.handle, url.absoluteString) }
        case .system, .data:
            break  // SF Symbols / raw bytes not mapped yet
        }
        let mode: Int32
        switch (spec.resizable, spec.contentMode) {
        case (false, _): mode = 0
        case (true, .some(.fit)): mode = 1
        case (true, .some(.fill)): mode = 2
        case (true, .none): mode = 3
        }
        hopwinui_image_set_stretch(handle.handle, mode)
    }

    public func configureDatePicker(_ handle: WinUIWidget, _ spec: DatePickerSpec) {
        handle.onChangeDate = spec.onChange
        handle.dpDate = spec.date
        let showDate = spec.components.contains(.date) || spec.components.isEmpty
        let showTime = spec.components.contains(.hourAndMinute)
        handle.suppress = true
        if let date = handle.datePart {
            hopwinui_set_visible(date, showDate ? 1 : 0)
            hopwinui_datepicker_set_date(date, spec.date.timeIntervalSince1970)
        }
        if let time = handle.timePart {
            hopwinui_set_visible(time, showTime ? 1 : 0)
            hopwinui_timepicker_set_time(time, Self.timeOfDay(spec.date))
        }
        handle.suppress = false
    }

    public func configureColorPicker(_ handle: WinUIWidget, _ spec: ColorPickerSpec) {
        handle.onChangeColor = spec.onChange
        hopwinui_colorpicker_set_alpha_enabled(handle.handle, spec.supportsOpacity ? 1 : 0)
        handle.suppress = true
        let c = spec.color
        hopwinui_colorpicker_set_color(handle.handle, c.red, c.green, c.blue, c.opacity)
        handle.suppress = false
    }

    // File dialogs: present once per `isPresented` true-edge (configure runs every reconcile, so reset the
    // binding immediately) and open the native FileOpenPicker / FileSavePicker via the shim; the async
    // result arrives on the UI thread through a retained result box.
    public func configureFileImporter(_ handle: WinUIWidget, _ spec: FileImporterSpec) {
        guard spec.isPresented else { return }
        spec.setPresented(false)
        let extensions = spec.allowedContentTypes.flatMap { $0.filenameExtensions }
        let box = FilesResultBox { spec.onCompletion(.success($0)) }
        withCStrings(extensions) { ptr in
            hopwinui_open_file_picker(ptr, Int32(extensions.count), spec.allowsMultipleSelection ? 1 : 0,
                                      cbFilesResult, Unmanaged.passRetained(box).toOpaque())
        }
    }

    public func configureFileExporter(_ handle: WinUIWidget, _ spec: FileExporterSpec) {
        guard spec.isPresented else { return }
        spec.setPresented(false)
        let data = spec.data
        let box = FileResultBox { url in
            guard let url else { return }
            do { try data.write(to: url); spec.onCompletion(.success(url)) }
            catch { spec.onCompletion(.failure(error)) }
        }
        hopwinui_save_file_picker(spec.defaultFilename, spec.contentType.preferredFilenameExtension ?? "",
                                  spec.contentType.displayName, cbFileResult, Unmanaged.passRetained(box).toOpaque())
    }

    public func configureAlert(_ handle: WinUIWidget, _ spec: AlertSpec) {
        guard spec.isPresented else { handle.alertPresenting = false; return }
        guard !handle.alertPresenting else { return }
        handle.alertPresenting = true
        let buttons = spec.buttons.isEmpty ? [AlertButton(title: "OK", role: nil, action: {})] : spec.buttons
        let box = AlertResultBox { [weak handle] index in
            handle?.alertPresenting = false
            spec.setPresented(false)
            if index >= 0, index < buttons.count { buttons[index].action() }
        }
        // ContentDialog supports up to 3 buttons (Primary/Secondary/Close); excess are dropped (logged-worthy).
        let labels = buttons.prefix(3).map(\.title).joined(separator: "\n")
        hopwinui_alert_show(spec.title, spec.message ?? "", labels, cbAlertResult, Unmanaged.passRetained(box).toOpaque())
    }

    public func configureSheet(_ handle: WinUIWidget, _ spec: SheetSpec) {
        guard spec.isPresented, let content = spec.content else {
            if let dialog = handle.sheetDialog { hopwinui_sheet_close(dialog) }
            handle.sheetDialog = nil; handle.sheetReconciler = nil
            if handle.sheetPresenting { spec.onDismiss?() }
            handle.sheetPresenting = false
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: 460, height: 360)
        if handle.sheetPresenting, let reconciler = handle.sheetReconciler {
            reconciler.update(content); reconciler.layout(in: bounds); return   // reactive update
        }
        handle.sheetPresenting = true
        let dialog = hopwinui_sheet_new()!
        let canvas = hopwinui_sheet_canvas(dialog)!
        let reconciler = Reconciler(toolkit: self)
        reconciler.mount(content, into: WinUIWidget(canvas, kind: .vstack, isPanel: true))
        reconciler.layout(in: bounds)
        handle.sheetDialog = dialog
        handle.sheetReconciler = reconciler
        let box = SheetDismissBox { [weak handle] in handle?.sheetPresenting = false; spec.setPresented(false) }
        hopwinui_sheet_show(dialog, cbSheetDismiss, Unmanaged.passRetained(box).toOpaque())
    }

    public func releaseHandle(_ handle: WinUIWidget) {
        guard handle.sheetPresenting else { return }
        if let dialog = handle.sheetDialog { hopwinui_sheet_close(dialog) }   // don't orphan the sheet
        handle.sheetDialog = nil
        handle.sheetReconciler = nil
        handle.sheetPresenting = false
    }

    public func configureTabs(_ handle: WinUIWidget, _ spec: TabSpec) {
        handle.tabOnSelect = spec.onSelect
        handle.tabSelected = max(0, min(spec.selectedIndex, max(0, handle.children.count - 1)))
        // Build (once) a horizontal strip of tab buttons; rebuild its buttons each reconcile.
        let strip: WinUIWidget
        if let existing = handle.tabStrip { strip = existing }
        else {
            strip = WinUIWidget(hopwinui_stackpanel_new(0), kind: .hstack, isPanel: true)
            hopwinui_panel_insert(handle.handle, strip.handle, Int32(handle.children.count))
            handle.tabStrip = strip
        }
        // Clear old buttons.
        for child in strip.children { hopwinui_panel_remove(strip.handle, child.handle) }
        strip.children.removeAll(); handle.tabButtonBoxes.removeAll()
        for (index, title) in spec.titles.enumerated() {
            let button = WinUIWidget(hopwinui_button_new(), kind: .button)
            hopwinui_button_set_text(button.handle, title)
            let box = TabButtonBox(handle, index)
            handle.tabButtonBoxes.append(box)
            hopwinui_button_connect(button.handle, cbTabButton, Unmanaged.passUnretained(box).toOpaque())
            hopwinui_panel_insert(strip.handle, button.handle, Int32(index))
            strip.children.append(button)
        }
        for (index, page) in handle.children.enumerated() where page !== strip {
            hopwinui_set_visible(page.handle, index == handle.tabSelected ? 1 : 0)
        }
    }

    // MARK: - Framework-owned layout

    public func setFrame(_ handle: WinUIWidget, _ rect: CGRect) {
        if handle.isScrollContent {
            hopwinui_set_size(handle.handle, Double(rect.width), Double(rect.height)); return
        }
        hopwinui_set_frame(handle.handle, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
        switch handle.kind {
        case .shape:
            handle.stampedSize = rect.size
            redrawShape(handle, CGRect(origin: .zero, size: rect.size))
        case .splitView:
            layoutSplitPanes(handle, size: rect.size)
        case .tabView:
            layoutTabPages(handle, size: rect.size)
        default:
            break
        }
    }

    private func layoutSplitPanes(_ handle: WinUIWidget, size: CGSize) {
        let panes = handle.children
        guard !panes.isEmpty else { return }
        let sidebar = min(CGFloat(260), size.width * 0.34)
        let frames: [CGRect] = panes.count >= 2
            ? [CGRect(x: 0, y: 0, width: sidebar, height: size.height),
               CGRect(x: sidebar, y: 0, width: size.width - sidebar, height: size.height)]
            : [CGRect(origin: .zero, size: size)]
        for (pane, frame) in zip(panes, frames) {
            hopwinui_set_frame(pane.handle, Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height))
            pane.stampedSize = frame.size
        }
    }

    private func layoutTabPages(_ handle: WinUIWidget, size: CGSize) {
        let stripHeight: CGFloat = 40
        if let strip = handle.tabStrip {
            hopwinui_set_frame(strip.handle, 0, 0, Double(size.width), Double(stripHeight))
        }
        let pageSize = CGSize(width: size.width, height: max(0, size.height - stripHeight))
        for (index, page) in handle.children.enumerated() where page !== handle.tabStrip {
            hopwinui_set_visible(page.handle, index == handle.tabSelected ? 1 : 0)
            guard index == handle.tabSelected else { continue }
            hopwinui_set_frame(page.handle, 0, Double(stripHeight), Double(pageSize.width), Double(pageSize.height))
            page.stampedSize = pageSize
        }
    }

    public func measure(_ handle: WinUIWidget, _ proposal: ProposedViewSize) -> CGSize {
        switch handle.kind {
        case .shape:
            return proposal.resolved(CGSize(width: 100, height: 100))
        case .textEditor:   // role .fill — greedily fills the offered space along both axes
            return proposal.resolved(CGSize(width: 240, height: 140))
        case .separator:
            return CGSize(width: proposal.width ?? 100, height: 1)
        case .image:
            return handle.imageResizable ? proposal.resolved(handle.imageNaturalSize) : handle.imageNaturalSize
        case .datePicker:
            var w = 0.0, h = 0.0
            hopwinui_measure(handle.handle, .infinity, .infinity, &w, &h)
            return CGSize(width: max(w, 240), height: max(h, 32))
        case .picker:
            // These controls' WinRT DesiredSize is unreliable (see `PickerRender`), so size them explicitly:
            // a ComboBox is a standard-height popup (capped width); a segmented group fills its width with
            // equal segments; an inline list fills its width and is tall enough to show every row.
            let offered = proposal.width ?? 240
            let rows = Double(Swift.max(1, handle.pickerOptions.count))
            switch handle.pickerRender {
            case .combo:     return CGSize(width: Swift.min(offered, 260), height: 32)
            case .segmented: return CGSize(width: offered, height: 32)
            case .radio:
                // A vertical RadioButton stack: keep its natural (content) width, but force the height to the
                // real laid-out row height (its `DesiredSize` reports an un-templated, too-short height, so the
                // rows would otherwise overflow + clip — like the segmented buttons did).
                var mw = 0.0, mh = 0.0
                hopwinui_measure(handle.handle, .infinity, .infinity, &mw, &mh)
                return CGSize(width: Swift.max(mw, 160), height: rows * 36 + 4)
            case .inline:    return CGSize(width: offered, height: rows * 36 + 8)
            case .none:      break
            }
        default:
            break
        }
        var w = 0.0, h = 0.0
        hopwinui_measure(handle.handle, proposal.width ?? .infinity, proposal.height ?? .infinity, &w, &h)
        if w <= 0 { w = proposal.width ?? 0 }
        if handle.flexibleWidth, let pw = proposal.width, pw.isFinite { w = Swift.max(pw, w) }
        return CGSize(width: w, height: h)
    }

    public func sizeOf(_ handle: WinUIWidget) -> CGSize {
        if let stamped = handle.stampedSize { return stamped }
        var w = 0.0, h = 0.0
        hopwinui_actual_size(handle.handle, &w, &h)
        return CGSize(width: w, height: h)
    }

    // MARK: - Shape drawing (replay the HopUI Path into the shim's geometry builder)

    private func redrawShape(_ handle: WinUIWidget, _ rect: CGRect) {
        guard let spec = handle.shapeSpec else { return }
        let h = handle.handle
        hopwinui_path_begin(h)
        for element in spec.path(rect).elements {
            switch element {
            case .move(let p): hopwinui_path_move(h, Double(p.x), Double(p.y))
            case .line(let p): hopwinui_path_line(h, Double(p.x), Double(p.y))
            case .quadCurve(let p, let c): hopwinui_path_quad(h, Double(c.x), Double(c.y), Double(p.x), Double(p.y))
            case .curve(let p, let c1, let c2): hopwinui_path_cubic(h, Double(c1.x), Double(c1.y), Double(c2.x), Double(c2.y), Double(p.x), Double(p.y))
            case .closeSubpath: hopwinui_path_close_figure(h, 1)
            case .rect(let r): hopwinui_path_add_rect(h, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
            case .roundedRect(let r, let cs):
                hopwinui_path_add_round_rect(h, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), Double(cs.width), Double(cs.height))
            case .ellipse(let r):
                hopwinui_path_add_ellipse(h, Double(r.midX), Double(r.midY), Double(r.width / 2), Double(r.height / 2))
            case .arc(let center, let radius, let start, let end, let clockwise):
                let sx = center.x + radius * CGFloat(cos(start.radians)), sy = center.y + radius * CGFloat(sin(start.radians))
                let ex = center.x + radius * CGFloat(cos(end.radians)), ey = center.y + radius * CGFloat(sin(end.radians))
                hopwinui_path_move(h, Double(sx), Double(sy))
                hopwinui_path_arc(h, Double(ex), Double(ey), Double(radius), clockwise ? 1 : 0, abs(end.radians - start.radians) > .pi ? 1 : 0)
            }
        }
        hopwinui_path_commit(h)
        if let gradient = spec.gradient {
            fillGradient(gradient, rect: rect, handle: h)
        } else if let fill = spec.fill {
            hopwinui_path_set_fill(h, fill.red, fill.green, fill.blue, fill.opacity)
        } else {
            hopwinui_path_clear_fill(h)
        }
        if let stroke = spec.stroke { hopwinui_path_set_stroke(h, stroke.red, stroke.green, stroke.blue, stroke.opacity, Double(spec.lineWidth)) } else { hopwinui_path_clear_stroke(h) }
        hopwinui_path_set_transform(h, Double(rect.width / 2), Double(rect.height / 2),
                                    Double(spec.offset.width), Double(spec.offset.height),
                                    spec.rotation.degrees, Double(spec.scaleX), Double(spec.scaleY))
    }

    /// Fill the path with a gradient brush. WinUI has Linear/RadialGradientBrush but no conic brush, so an
    /// angular gradient is approximated with a center-out radial brush (documented limitation).
    private func fillGradient(_ spec: GradientSpec, rect: CGRect, handle h: UnsafeMutableRawPointer) {
        switch spec.kind {
        case .linear(let start, let end):
            let p0 = start.point(in: rect), p1 = end.point(in: rect)
            var packed = Self.packStops(spec.stops)
            packed.withUnsafeBufferPointer { buf in
                hopwinui_path_set_fill_linear(h, Double(p0.x), Double(p0.y), Double(p1.x), Double(p1.y),
                                              buf.baseAddress, Int32(spec.stops.count))
            }
        case .radial(let center, let r0, let r1):
            let c = center.point(in: rect)
            let end = Swift.max(Double(r1), 0.0001)
            let remapped = spec.stops.map {
                Gradient.Stop(color: $0.color, location: CGFloat((Double(r0) + Double($0.location) * (Double(r1) - Double(r0))) / end))
            }
            var packed = Self.packStops(remapped)
            packed.withUnsafeBufferPointer { buf in
                hopwinui_path_set_fill_radial(h, Double(c.x), Double(c.y), end, end, buf.baseAddress, Int32(remapped.count))
            }
        case .angular(let center, _, _):
            let c = center.point(in: rect)
            let radius = (Double(rect.width) * Double(rect.width) + Double(rect.height) * Double(rect.height)).squareRoot() / 2
            var packed = Self.packStops(spec.stops)
            packed.withUnsafeBufferPointer { buf in
                hopwinui_path_set_fill_radial(h, Double(c.x), Double(c.y), radius, radius, buf.baseAddress, Int32(spec.stops.count))
            }
        }
    }

    private static func packStops(_ stops: [Gradient.Stop]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(stops.count * 5)
        for stop in stops {
            out.append(Double(stop.location))
            out.append(stop.color.red); out.append(stop.color.green); out.append(stop.color.blue); out.append(stop.color.opacity)
        }
        return out
    }

    // MARK: - App / run loop

    public func run(title: String, onReady: @escaping @MainActor (WinUIWidget) -> Void) {
        onReadyClosure = onReady
        hopwinui_run(title, cbReady, Unmanaged.passUnretained(self).toOpaque())  // blocks: owns the message loop
    }

    /// Called from the shim's on-ready callback (UI thread) with the root Canvas handle.
    func handleReady(_ root: UnsafeMutableRawPointer) {
        installWinUIMainExecutor()
        hopwinui_set_relayout(cbRelayout, Unmanaged.passUnretained(self).toOpaque())
        let container = WinUIWidget(root, kind: .window, isPanel: true)
        onReadyClosure?(container)
    }

    public func openWindow(title: String, onReady: @escaping @MainActor (WinUIWidget) -> Void) {
        let box = SecondaryReady(onReady)
        secondaryBoxes.append(box)
        hopwinui_open_window(title, cbSecondaryReady, Unmanaged.passUnretained(box).toOpaque())
    }
    private var secondaryBoxes: [SecondaryReady] = []

    public func setToolbar(_ items: [ToolbarItemSpec]) {}  // WinUI windows have no system toolbar (MVP no-op)
    public func setMenu(_ menus: [MenuSpec]) {}            // nor a native menu bar; edit commands are native
    // No `handlesNavigationBarNatively`: a full-width window header band would displace the sidebar (and the
    // shim can't confine it to the detail column). Instead `NavigationStack` renders its title as a styled
    // in-content header inside the detail pane, leaving the sidebar full-height.

    public func scheduleOnMainThread(_ work: @escaping @MainActor () -> Void) {
        hopwinui_schedule_on_main(cbScheduleWork, Unmanaged.passRetained(ScheduledWork(work)).toOpaque())
    }

    public func setColorScheme(_ colorScheme: ColorScheme?) {
        hopwinui_set_color_scheme(colorScheme == .light ? 1 : colorScheme == .dark ? 2 : 0)
    }

    public func contentSize() -> CGSize {
        var w = 0.0, h = 0.0
        hopwinui_content_size(&w, &h)
        return CGSize(width: w, height: h)
    }

    public func setRelayoutHandler(_ handler: @escaping @MainActor () -> Void) { relayoutHandler = handler }

    // MARK: - Date helpers (UTC-relative; match the shim's seconds-since-1970 / seconds-of-day convention)

    private static let secondsPerDay: Double = 86_400
    static func timeOfDay(_ date: Date) -> Double {
        let t = date.timeIntervalSince1970
        return t - (t / secondsPerDay).rounded(.down) * secondsPerDay
    }
    static func compose(day: Date, secondsIntoDay: Double) -> Date {
        let dayStart = (day.timeIntervalSince1970 / secondsPerDay).rounded(.down) * secondsPerDay
        return Date(timeIntervalSince1970: dayStart + secondsIntoDay)
    }
}

// MARK: - Menu action boxes + secondary-window readiness

/// Retains a menu item's action so the shim's C callback can reach it.
final class MenuActionBox {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
}
private let cbMenuItem: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
    guard let ud else { return }
    let box = Unmanaged<MenuActionBox>.fromOpaque(ud).takeUnretainedValue()
    MainActor.assumeIsolated { box.action() }
}

/// Carries a file-open picker's completion across the C boundary (retained until the async result fires).
final class FilesResultBox {
    let completion: @MainActor ([URL]) -> Void
    init(_ completion: @escaping @MainActor ([URL]) -> Void) { self.completion = completion }
}

/// Carries an `.alert`'s choice handler (index of the clicked button, -1 if dismissed) across the C callback.
final class AlertResultBox {
    let onChoose: @MainActor (Int) -> Void
    init(_ onChoose: @escaping @MainActor (Int) -> Void) { self.onChoose = onChoose }
}
private let cbAlertResult: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { index, ud in
    guard let ud else { return }
    let box = Unmanaged<AlertResultBox>.fromOpaque(ud).takeRetainedValue()
    MainActor.assumeIsolated { box.onChoose(Int(index)) }
}

/// Carries a `.sheet`'s dismiss handler (the dialog closed) across the C callback.
final class SheetDismissBox {
    let onDismiss: @MainActor () -> Void
    init(_ onDismiss: @escaping @MainActor () -> Void) { self.onDismiss = onDismiss }
}
private let cbSheetDismiss: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
    guard let ud else { return }
    let box = Unmanaged<SheetDismissBox>.fromOpaque(ud).takeRetainedValue()
    MainActor.assumeIsolated { box.onDismiss() }
}
private let cbFilesResult: @convention(c) (UnsafePointer<UnsafePointer<CChar>?>?, Int32, UnsafeMutableRawPointer?) -> Void = { paths, count, ud in
    guard let ud else { return }
    let box = Unmanaged<FilesResultBox>.fromOpaque(ud).takeRetainedValue()
    var urls: [URL] = []
    if let paths { for i in 0 ..< Int(count) { if let p = paths[i] { urls.append(URL(fileURLWithPath: String(cString: p))) } } }
    MainActor.assumeIsolated { box.completion(urls) }
}

/// Carries a file-save picker's completion across the C boundary.
final class FileResultBox {
    let completion: @MainActor (URL?) -> Void
    init(_ completion: @escaping @MainActor (URL?) -> Void) { self.completion = completion }
}
private let cbFileResult: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { path, ud in
    guard let ud else { return }
    let box = Unmanaged<FileResultBox>.fromOpaque(ud).takeRetainedValue()
    let url = path.map { URL(fileURLWithPath: String(cString: $0)) }
    MainActor.assumeIsolated { box.completion(url) }
}

/// Carries a secondary window's on-ready closure across the C boundary.
final class SecondaryReady {
    let onReady: @MainActor (WinUIWidget) -> Void
    init(_ onReady: @escaping @MainActor (WinUIWidget) -> Void) { self.onReady = onReady }
}
private let cbSecondaryReady: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { root, ud in
    guard let root, let ud else { return }
    let rootBits = UInt(bitPattern: root)
    let box = Unmanaged<SecondaryReady>.fromOpaque(ud).takeUnretainedValue()
    MainActor.assumeIsolated { box.onReady(WinUIWidget(UnsafeMutableRawPointer(bitPattern: rootBits)!, kind: .window, isPanel: true)) }
}

// MARK: - Helpers

/// Call `body` with a C array of UTF-8 C strings for `strings` (valid only during the call).
private func withCStrings(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> Void) {
    func recurse(_ index: Int, _ pointers: [UnsafePointer<CChar>?]) {
        if index == strings.count {
            pointers.withUnsafeBufferPointer { body($0.baseAddress) }
            return
        }
        strings[index].withCString { recurse(index + 1, pointers + [$0]) }
    }
    recurse(0, [])
}
