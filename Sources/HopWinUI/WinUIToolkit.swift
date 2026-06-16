// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import WinUI
import WinAppSDK
import UWP
import WindowsFoundation
import HopUI
import Foundation
import Dispatch

// The WinUI 3 (Windows App SDK) toolkit. It binds HopUI's toolkit-agnostic ``RenderToolkit`` seam to real
// XAML controls via the swift-winui WinRT projections: every container is a `Canvas` (HopUI's layout engine
// owns all geometry and places children absolutely via `setFrame`), and leaves map onto
// `TextBlock`/`Button`/`TextBox`/`PasswordBox`/`ToggleSwitch`/`Slider`/`ComboBox`/`ListView`/`ProgressBar`/
// `Image`/`Microsoft.UI.Xaml.Shapes.Path`. The app runs the Windows App SDK's XAML `Application` loop (the
// demo's `SwiftApplication` entry point owns it); `run` just creates the `Window` and returns.

/// Opaque handle wrapping a XAML `FrameworkElement` (plus the per-widget callbacks and bookkeeping the
/// reconciler needs). For container kinds, `panel` is the `Canvas` engine-placed children are inserted into.
public final class WinUIWidget {
    let element: WinUI.FrameworkElement
    let kind: WidgetKind
    var panel: WinUI.Panel?
    /// Child handles, kept parallel to `panel.children`, so reorder/remove and native-pane layout are
    /// index-stable (WinRT's `UIElementCollection.indexOf` over erased `UIElement`s is awkward).
    var children: [WinUIWidget] = []

    // Role-derived behavior.
    var flexibleWidth = false            // text fields / sliders / progress bars fill the offered width
    var isScrollContent = false          // a ScrollViewer's single content child (sized, not positioned)
    var imageResizable = false
    var imageNaturalSize = CGSize(width: 24, height: 24)

    // Stored callbacks (installed by setAction / set*Handler / configure*).
    var action: (@MainActor () -> Void)?
    var onChangeString: (@MainActor (String) -> Void)?
    var onChangeDouble: (@MainActor (Double) -> Void)?
    var onChangeBool: (@MainActor (Bool) -> Void)?
    var onSelectIndex: (@MainActor (Int?) -> Void)?
    var pickerOnSelect: (@MainActor (Int) -> Void)?
    var onChangeDate: (@MainActor (Date) -> Void)?
    var onChangeColor: (@MainActor (HopUI.Color) -> Void)?
    var outlineOnSelect: (@MainActor (AnyHashable?) -> Void)?
    var tabOnSelect: (@MainActor (Int) -> Void)?
    var scrollHandler: (@MainActor (CGSize) -> Void)?

    /// Suppresses change callbacks while we reflect a bound value programmatically (avoids feedback loops).
    var suppress = false

    // Caches to skip redundant native work / disturbing in-progress edits.
    var listCount = -1
    var pickerOptions: [String] = []
    var outlineSignature: String?
    var outlineKeyByRow: [String] = []
    var outlineIDByKey: [String: AnyHashable] = [:]

    // `.shape` state, drawn on each `setFrame` (once the engine has chosen the frame).
    var shapeSpec: ShapeSpec?
    // `.tabView` state: the tab-button strip and the current page.
    var tabStrip: WinUI.StackPanel?
    var tabSelected = 0
    // `.datePicker` state: WinUI splits date and time editing into two controls, hosted side by side; which
    // are shown depends on the bound `DatePickerComponents`. `dpDate` is the current combined value, so a
    // partial edit (date-only or time-only) can be merged back with the other component.
    var datePart: WinUI.CalendarDatePicker?
    var timePart: WinUI.TimePicker?
    var dpDate = Date(timeIntervalSince1970: 0)
    // Size stamped by `setFrame` for native panes (read back by `sizeOf`).
    var stampedSize: CGSize?
    // Retained event registrations (kept alive for the widget's lifetime).
    var cleanups: [EventCleanup] = []

    init(_ element: WinUI.FrameworkElement, kind: WidgetKind, panel: WinUI.Panel? = nil) {
        self.element = element
        self.kind = kind
        self.panel = panel
    }
}

public final class WinUIToolkit: AppToolkit {
    public typealias Handle = WinUIWidget

    private var window: WinUI.Window?
    private var rootCanvas: WinUI.Canvas?
    private var relayoutHandler: (@MainActor () -> Void)?
    private var secondaryWindows: [WinUI.Window] = []
    // Tab-strip button trampolines / menu items are retained via each widget's `cleanups`.

    public init() {}

    // MARK: - Widget creation

    public func makeWidget(_ kind: WidgetKind) -> WinUIWidget {
        switch kind {
        case .vstack, .hstack, .zstack, .spacer, .geometry, .lazyStack, .window:
            let canvas = WinUI.Canvas()
            return WinUIWidget(canvas, kind: kind, panel: canvas)

        case .groupBox:
            // A subtle filled "card" backing; the engine lays the content out as a vertical stack on top.
            let canvas = WinUI.Canvas()
            canvas.background = Self.brush(HopUI.Color(red: 0.5, green: 0.5, blue: 0.5, opacity: 0.10))
            return WinUIWidget(canvas, kind: kind, panel: canvas)

        case .splitView, .tabView:
            let canvas = WinUI.Canvas()
            return WinUIWidget(canvas, kind: kind, panel: canvas)

        case .scroll:
            let scroll = WinUI.ScrollViewer()
            scroll.horizontalScrollMode = .disabled
            scroll.verticalScrollMode = .auto
            scroll.verticalScrollBarVisibility = .auto
            scroll.horizontalScrollBarVisibility = .disabled
            let widget = WinUIWidget(scroll, kind: kind)
            let cleanup = scroll.viewChanged.addHandler { [weak widget, weak scroll] _, _ in
                guard let widget, let scroll else { return }
                MainActor.assumeIsolated {
                    widget.scrollHandler?(CGSize(width: scroll.horizontalOffset, height: scroll.verticalOffset))
                }
            }
            widget.cleanups.append(cleanup)
            return widget

        case .label:
            let label = WinUI.TextBlock()
            label.textWrapping = .wrap
            return WinUIWidget(label, kind: kind)

        case .button:
            let button = WinUI.Button()
            let widget = WinUIWidget(button, kind: kind)
            let cleanup = button.click.addHandler { [weak widget] _, _ in
                guard let widget, !widget.suppress else { return }
                MainActor.assumeIsolated { widget.action?() }
            }
            widget.cleanups.append(cleanup)
            return widget

        case .textField:
            let field = WinUI.TextBox()
            let widget = WinUIWidget(field, kind: kind)
            widget.flexibleWidth = true
            let cleanup = field.textChanged.addHandler { [weak widget, weak field] _, _ in
                guard let widget, let field, !widget.suppress else { return }
                MainActor.assumeIsolated { widget.onChangeString?(field.text) }
            }
            widget.cleanups.append(cleanup)
            return widget

        case .secureField:
            let field = WinUI.PasswordBox()
            let widget = WinUIWidget(field, kind: kind)
            widget.flexibleWidth = true
            let cleanup = field.passwordChanged.addHandler { [weak widget, weak field] _, _ in
                guard let widget, let field, !widget.suppress else { return }
                MainActor.assumeIsolated { widget.onChangeString?(field.password) }
            }
            widget.cleanups.append(cleanup)
            return widget

        case .toggle:
            let toggle = WinUI.ToggleSwitch()
            let widget = WinUIWidget(toggle, kind: kind)
            let cleanup = toggle.toggled.addHandler { [weak widget, weak toggle] _, _ in
                guard let widget, let toggle, !widget.suppress else { return }
                MainActor.assumeIsolated { widget.onChangeBool?(toggle.isOn) }
            }
            widget.cleanups.append(cleanup)
            return widget

        case .slider:
            let slider = WinUI.Slider()
            slider.minimum = 0
            slider.maximum = 1
            slider.stepFrequency = 0.0001
            let widget = WinUIWidget(slider, kind: kind)
            widget.flexibleWidth = true
            let cleanup = slider.valueChanged.addHandler { [weak widget, weak slider] _, _ in
                guard let widget, let slider, !widget.suppress else { return }
                MainActor.assumeIsolated { widget.onChangeDouble?(slider.value) }
            }
            widget.cleanups.append(cleanup)
            return widget

        case .list, .sidebarList, .outline, .sidebarOutline:
            let listView = WinUI.ListView()
            let widget = WinUIWidget(listView, kind: kind)
            let cleanup = listView.selectionChanged.addHandler { [weak widget, weak listView] _, _ in
                guard let widget, let listView, !widget.suppress else { return }
                MainActor.assumeIsolated {
                    let index = Int(listView.selectedIndex)
                    if widget.kind == .outline || widget.kind == .sidebarOutline {
                        let id = (index >= 0 && index < widget.outlineKeyByRow.count)
                            ? widget.outlineIDByKey[widget.outlineKeyByRow[index]] : nil
                        widget.outlineOnSelect?(id)
                    } else {
                        widget.onSelectIndex?(index >= 0 ? index : nil)
                    }
                }
            }
            widget.cleanups.append(cleanup)
            return widget

        case .shape:
            let path = WinUI.Path()
            path.stretch = .none
            return WinUIWidget(path, kind: kind)

        case .image:
            let image = WinUI.Image()
            return WinUIWidget(image, kind: kind)

        case .menu:
            let button = WinUI.Button()
            return WinUIWidget(button, kind: kind)

        case .picker:
            let combo = WinUI.ComboBox()
            let widget = WinUIWidget(combo, kind: kind)
            let cleanup = combo.selectionChanged.addHandler { [weak widget, weak combo] _, _ in
                guard let widget, let combo, !widget.suppress else { return }
                MainActor.assumeIsolated {
                    let index = Int(combo.selectedIndex)
                    if index >= 0 { widget.pickerOnSelect?(index) }
                }
            }
            widget.cleanups.append(cleanup)
            return widget

        case .datePicker:
            // WinUI has no single date+time control: CalendarDatePicker edits the date and TimePicker the
            // time. Host both in a row; configureDatePicker shows whichever the bound DatePickerComponents
            // ask for (e.g. `.date` → date only, `.hourAndMinute` → time only, both → both). CalendarDatePicker
            // sizes to *stretch*, so pin a minimum width or it collapses to nothing when offered an
            // unconstrained (HStack) width.
            let row = WinUI.StackPanel()
            row.orientation = .horizontal
            row.spacing = 8
            row.horizontalAlignment = .left
            let datePart = WinUI.CalendarDatePicker()
            datePart.minWidth = 240
            let timePart = WinUI.TimePicker()
            timePart.minWidth = 150  // reserve room so it isn't squeezed out beside the date control
            row.children.append(datePart)
            row.children.append(timePart)
            let widget = WinUIWidget(row, kind: kind)
            widget.datePart = datePart
            widget.timePart = timePart
            // A date edit keeps the existing time-of-day; a time edit keeps the existing day. Merge through
            // `dpDate` so the unedited component is preserved, then report the combined Date.
            let dateCleanup = datePart.dateChanged.addHandler { [weak widget, weak datePart] _, _ in
                guard let widget, let datePart, !widget.suppress, let dt = datePart.date else { return }
                MainActor.assumeIsolated {
                    let merged = Self.compose(day: Self.date(from: dt), secondsIntoDay: Self.timeOfDay(widget.dpDate))
                    widget.dpDate = merged
                    widget.onChangeDate?(merged)
                }
            }
            let timeCleanup = timePart.timeChanged.addHandler { [weak widget, weak timePart] _, _ in
                guard let widget, let timePart, !widget.suppress else { return }
                MainActor.assumeIsolated {
                    let merged = Self.compose(day: widget.dpDate, secondsIntoDay: Double(timePart.time.duration) / 10_000_000)
                    widget.dpDate = merged
                    widget.onChangeDate?(merged)
                }
            }
            widget.cleanups.append(dateCleanup)
            widget.cleanups.append(timeCleanup)
            return widget

        case .colorPicker:
            // WinUI's inline ColorPicker (a full picker surface: spectrum + sliders), bound to the Color.
            let picker = WinUI.ColorPicker()
            let widget = WinUIWidget(picker, kind: kind)
            let cleanup = picker.colorChanged.addHandler { [weak widget, weak picker] _, _ in
                guard let widget, let picker, !widget.suppress else { return }
                MainActor.assumeIsolated {
                    let c = picker.color
                    widget.onChangeColor?(HopUI.Color(red: Double(c.r) / 255, green: Double(c.g) / 255,
                                                      blue: Double(c.b) / 255, opacity: Double(c.a) / 255))
                }
            }
            widget.cleanups.append(cleanup)
            return widget

        case .separator:
            let line = WinUI.Border()
            line.background = Self.brush(HopUI.Color(red: 0.5, green: 0.5, blue: 0.5, opacity: 0.4))
            return WinUIWidget(line, kind: kind)

        case .progress:
            let bar = WinUI.ProgressBar()
            bar.minimum = 0
            bar.maximum = 1
            let widget = WinUIWidget(bar, kind: kind)
            widget.flexibleWidth = true
            return widget
        }
    }

    // MARK: - Configuration

    public func configure(_ handle: WinUIWidget, _ patch: WidgetPatch) {
        if let text = patch.text, let label = handle.element as? WinUI.TextBlock {
            label.text = text
        }
        if let title = patch.title, let button = handle.element as? WinUI.Button {
            button.content = title
        }
        if let placeholder = patch.placeholder {
            if let field = handle.element as? WinUI.TextBox { field.placeholderText = placeholder }
            else if let field = handle.element as? WinUI.PasswordBox { field.placeholderText = placeholder }
        }
        if let value = patch.value {
            handle.suppress = true
            if let field = handle.element as? WinUI.TextBox, field.text != value { field.text = value }
            else if let field = handle.element as? WinUI.PasswordBox, field.password != value { field.password = value }
            handle.suppress = false
        }
        if let slider = handle.element as? WinUI.Slider {
            if let minV = patch.minValue { slider.minimum = minV }
            if let maxV = patch.maxValue { slider.maximum = maxV }
            if let v = patch.doubleValue, abs(slider.value - v) > 0.0001 {
                handle.suppress = true; slider.value = v; handle.suppress = false
            }
        }
        if let on = patch.boolValue, let toggle = handle.element as? WinUI.ToggleSwitch, toggle.isOn != on {
            handle.suppress = true; toggle.isOn = on; handle.suppress = false
        }

        // Text styling (foreground / font) on labels.
        if let label = handle.element as? WinUI.TextBlock {
            if let fg = patch.foregroundColor { label.foreground = Self.brush(fg) }
            if let font = patch.font {
                label.fontSize = font.size
                if let family = font.family { label.fontFamily = WinUI.FontFamily(family) }
            }
            if let weight = patch.fontWeight ?? patch.font?.weight {
                label.fontWeight = Self.fontWeight(weight)
            }
        }

        // Background fill (containers / controls that expose Background).
        if let bg = patch.backgroundColor {
            if let panel = handle.panel { panel.background = Self.brush(bg) }
            else if let control = handle.element as? WinUI.Control { control.background = Self.brush(bg) }
            else if let border = handle.element as? WinUI.Border { border.background = Self.brush(bg) }
        }

        // Progress: a fraction is determinate; nil is the indeterminate animation.
        if let bar = handle.element as? WinUI.ProgressBar {
            if let value = patch.progressValue { bar.isIndeterminate = false; bar.value = value }
            else { bar.isIndeterminate = true }
        }

        // Accessibility → UI Automation.
        if let label = patch.accessibilityLabel { WinUI.AutomationProperties.setName(handle.element, label) }
        if let identifier = patch.accessibilityIdentifier {
            WinUI.AutomationProperties.setAutomationId(handle.element, identifier)
        }
        if let help = patch.accessibilityHint ?? patch.accessibilityValue {
            WinUI.AutomationProperties.setHelpText(handle.element, help)
        }
    }

    // MARK: - Tree mutation

    public func insert(_ child: WinUIWidget, into parent: WinUIWidget, at index: Int) {
        if let scroll = parent.element as? WinUI.ScrollViewer {
            child.isScrollContent = true
            scroll.content = child.element
            parent.children = [child]
            return
        }
        guard let panel = parent.panel else { return }
        let clamped = max(0, min(index, parent.children.count))
        panel.children.insertAt(UInt32(clamped), child.element)
        parent.children.insert(child, at: clamped)
    }

    public func move(_ child: WinUIWidget, in parent: WinUIWidget, to index: Int) {
        guard let panel = parent.panel,
              let from = parent.children.firstIndex(where: { $0 === child }) else { return }
        panel.children.removeAt(UInt32(from))
        parent.children.remove(at: from)
        let clamped = max(0, min(index, parent.children.count))
        panel.children.insertAt(UInt32(clamped), child.element)
        parent.children.insert(child, at: clamped)
    }

    public func remove(_ child: WinUIWidget, from parent: WinUIWidget) {
        if let scroll = parent.element as? WinUI.ScrollViewer {
            scroll.content = nil
            parent.children.removeAll { $0 === child }
            return
        }
        guard let panel = parent.panel,
              let idx = parent.children.firstIndex(where: { $0 === child }) else { return }
        panel.children.removeAt(UInt32(idx))
        parent.children.remove(at: idx)
    }

    public func setAction(_ handle: WinUIWidget, _ action: (@MainActor () -> Void)?) { handle.action = action }
    public func setTextHandler(_ handle: WinUIWidget, _ handler: (@MainActor (String) -> Void)?) { handle.onChangeString = handler }
    public func setValueHandler(_ handle: WinUIWidget, _ handler: (@MainActor (Double) -> Void)?) { handle.onChangeDouble = handler }
    public func setBoolHandler(_ handle: WinUIWidget, _ handler: (@MainActor (Bool) -> Void)?) { handle.onChangeBool = handler }

    public func setScrollHandler(_ handle: WinUIWidget, _ handler: (@MainActor (CGSize) -> Void)?) {
        handle.scrollHandler = handler
    }

    // MARK: - Composite configuration

    public func configureList(_ handle: WinUIWidget, _ spec: ListSpec) {
        guard let listView = handle.element as? WinUI.ListView else { return }
        handle.onSelectIndex = spec.onSelect
        if handle.listCount != spec.count {
            handle.listCount = spec.count
            listView.items?.clear()
            for i in 0 ..< spec.count { listView.items?.append(spec.rowText(i)) }
        }
        let target = Int32(spec.selectedIndex ?? -1)
        if listView.selectedIndex != target {
            handle.suppress = true; listView.selectedIndex = target; handle.suppress = false
        }
    }

    public func configureOutline(_ handle: WinUIWidget, _ spec: OutlineSpec) {
        guard let listView = handle.element as? WinUI.ListView else { return }
        handle.outlineOnSelect = spec.onSelect
        let signature = spec.structureSignature
        if handle.outlineSignature != signature {
            handle.outlineSignature = signature
            let flat = spec.flattened()
            handle.outlineKeyByRow = flat.map { $0.node.key }
            handle.outlineIDByKey = Dictionary(flat.map { ($0.node.key, $0.node.id) }, uniquingKeysWith: { a, _ in a })
            listView.items?.clear()
            for (node, depth) in flat {
                // Indent nested rows so the flattened tree reads hierarchically (no native disclosure here).
                listView.items?.append(String(repeating: "    ", count: depth) + node.title)
            }
        }
        let targetKey = spec.selectedID.map { "\($0.base)" }
        let targetRow = Int32(targetKey.flatMap { handle.outlineKeyByRow.firstIndex(of: $0) } ?? -1)
        if listView.selectedIndex != targetRow {
            handle.suppress = true; listView.selectedIndex = targetRow; handle.suppress = false
        }
    }

    public func configurePicker(_ handle: WinUIWidget, _ spec: PickerSpec) {
        guard let combo = handle.element as? WinUI.ComboBox else { return }
        handle.pickerOnSelect = spec.onSelect
        if handle.pickerOptions != spec.options {
            handle.pickerOptions = spec.options
            combo.items?.clear()
            for option in spec.options { combo.items?.append(option) }
        }
        let target = Int32(spec.selectedIndex ?? -1)
        if combo.selectedIndex != target {
            handle.suppress = true; combo.selectedIndex = target; handle.suppress = false
        }
    }

    public func configureDatePicker(_ handle: WinUIWidget, _ spec: DatePickerSpec) {
        handle.onChangeDate = spec.onChange
        handle.dpDate = spec.date
        // Show the date and/or time control per the bound components, and reflect the current value into each
        // (bounds and the graphical style aren't mapped here). `.date` ⇒ date only; `.hourAndMinute` ⇒ time
        // only; both ⇒ both, side by side. Default to the date control if neither is requested.
        let showDate = spec.components.contains(.date) || spec.components.isEmpty
        let showTime = spec.components.contains(.hourAndMinute)
        handle.suppress = true
        if let datePart = handle.datePart {
            datePart.visibility = showDate ? .visible : .collapsed
            datePart.date = Self.dateTime(from: spec.date)
        }
        if let timePart = handle.timePart {
            timePart.visibility = showTime ? .visible : .collapsed
            timePart.time = WindowsFoundation.TimeSpan(duration: Int64(Self.timeOfDay(spec.date) * 10_000_000))
        }
        handle.suppress = false
    }

    public func configureColorPicker(_ handle: WinUIWidget, _ spec: ColorPickerSpec) {
        guard let picker = handle.element as? WinUI.ColorPicker else { return }
        handle.onChangeColor = spec.onChange
        picker.isAlphaEnabled = spec.supportsOpacity
        handle.suppress = true
        picker.color = Self.uwpColor(spec.color)
        handle.suppress = false
    }

    public func configureMenu(_ handle: WinUIWidget, _ menu: MenuContent) {
        guard let button = handle.element as? WinUI.Button else { return }
        button.content = menu.label
        let flyout = WinUI.MenuFlyout()
        handle.cleanups.removeAll()
        buildMenu(menu.entries, into: flyout.items, cleanups: &handle.cleanups)
        button.flyout = flyout
    }

    private func buildMenu(_ entries: [MenuEntry], into items: WindowsFoundation.AnyIVector<WinUI.MenuFlyoutItemBase?>?,
                           cleanups: inout [EventCleanup]) {
        guard let items else { return }
        for entry in entries {
            switch entry {
            case .separator:
                items.append(WinUI.MenuFlyoutSeparator())
            case .button(let title, let action):
                let item = WinUI.MenuFlyoutItem()
                item.text = title
                let cleanup = item.click.addHandler { _, _ in MainActor.assumeIsolated { action() } }
                cleanups.append(cleanup)
                items.append(item)
            case .submenu(let title, let subEntries):
                let sub = WinUI.MenuFlyoutSubItem()
                sub.text = title
                buildMenu(subEntries, into: sub.items, cleanups: &cleanups)
                items.append(sub)
            }
        }
    }

    public func configureShape(_ handle: WinUIWidget, _ spec: ShapeSpec) {
        handle.shapeSpec = spec
        if let size = handle.stampedSize { redrawShape(handle, CGRect(origin: .zero, size: size)) }
    }

    public func configureImage(_ handle: WinUIWidget, _ spec: ImageSpec) {
        guard let image = handle.element as? WinUI.Image else { return }
        handle.imageResizable = spec.resizable
        switch spec.source {
        case .file, .named:
            if let url = spec.resolvedURL() {
                image.source = WinUI.BitmapImage(WindowsFoundation.Uri(url.absoluteString))
            }
        case .system:
            // WinUI has no SF Symbols; leave the image empty (a best-effort FontIcon fallback is future work).
            image.source = nil
        case .data:
            // Decoding raw bytes needs an InMemoryRandomAccessStream; not wired in the MVP.
            image.source = nil
        }
        switch (spec.resizable, spec.contentMode) {
        case (false, _): image.stretch = .none
        case (true, .some(.fit)): image.stretch = .uniform
        case (true, .some(.fill)): image.stretch = .uniformToFill
        case (true, .none): image.stretch = .fill
        }
    }

    public func configureTabs(_ handle: WinUIWidget, _ spec: TabSpec) {
        handle.tabOnSelect = spec.onSelect
        handle.tabSelected = max(0, min(spec.selectedIndex, max(0, handle.children.count - 1)))
        guard let canvas = handle.panel else { return }

        // Build (once) a horizontal strip of tab buttons; rebuild when the title set changes.
        let strip: WinUI.StackPanel
        if let existing = handle.tabStrip { strip = existing }
        else {
            strip = WinUI.StackPanel()
            strip.orientation = .horizontal
            strip.spacing = 6
            canvas.children.append(strip)
            handle.tabStrip = strip
        }
        strip.children?.clear()
        handle.cleanups.removeAll()
        for (index, title) in spec.titles.enumerated() {
            let button = WinUI.Button()
            button.content = title
            let cleanup = button.click.addHandler { [weak handle] _, _ in
                guard let handle else { return }
                MainActor.assumeIsolated { handle.tabOnSelect?(index) }
            }
            handle.cleanups.append(cleanup)
            strip.children?.append(button)
        }
        // Reflect selection: show only the selected page (others collapsed); positions set in setFrame.
        for (index, page) in handle.children.enumerated() {
            page.element.visibility = (index == handle.tabSelected ? .visible : .collapsed)
        }
    }

    // MARK: - Framework-owned layout

    public func setFrame(_ handle: WinUIWidget, _ rect: CGRect) {
        let element = handle.element
        if handle.isScrollContent {
            element.width = Double(rect.width)
            element.height = Double(rect.height)
            return
        }
        WinUI.Canvas.setLeft(element, Double(rect.minX))
        WinUI.Canvas.setTop(element, Double(rect.minY))
        element.width = Double(rect.width)
        element.height = Double(rect.height)

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

    /// Place a split view's two panes side by side (a fixed-width sidebar + a flexible detail), stamping each
    /// pane's size so `sizeOf` can report it (the engine lays out each pane's content within that size).
    private func layoutSplitPanes(_ handle: WinUIWidget, size: CGSize) {
        let panes = handle.children
        guard !panes.isEmpty else { return }
        let sidebarWidth = min(CGFloat(260), size.width * 0.34)
        let frames: [CGRect]
        if panes.count >= 2 {
            frames = [CGRect(x: 0, y: 0, width: sidebarWidth, height: size.height),
                      CGRect(x: sidebarWidth, y: 0, width: size.width - sidebarWidth, height: size.height)]
        } else {
            frames = [CGRect(origin: .zero, size: size)]
        }
        for (pane, frame) in zip(panes, frames) {
            WinUI.Canvas.setLeft(pane.element, Double(frame.minX))
            WinUI.Canvas.setTop(pane.element, Double(frame.minY))
            pane.element.width = Double(frame.width)
            pane.element.height = Double(frame.height)
            pane.stampedSize = frame.size
        }
    }

    /// Place a tab view's strip + selected page; stamp the page's content size for `sizeOf`.
    private func layoutTabPages(_ handle: WinUIWidget, size: CGSize) {
        let stripHeight: CGFloat = 40
        if let strip = handle.tabStrip {
            WinUI.Canvas.setLeft(strip, 0)
            WinUI.Canvas.setTop(strip, 0)
            strip.width = Double(size.width)
            strip.height = Double(stripHeight)
        }
        let pageSize = CGSize(width: size.width, height: max(0, size.height - stripHeight))
        for (index, page) in handle.children.enumerated() {
            page.element.visibility = (index == handle.tabSelected ? .visible : .collapsed)
            guard index == handle.tabSelected else { continue }
            WinUI.Canvas.setLeft(page.element, 0)
            WinUI.Canvas.setTop(page.element, Double(stripHeight))
            page.element.width = Double(pageSize.width)
            page.element.height = Double(pageSize.height)
            page.stampedSize = pageSize
        }
    }

    public func measure(_ handle: WinUIWidget, _ proposal: ProposedViewSize) -> CGSize {
        switch handle.kind {
        case .shape:
            return proposal.resolved(CGSize(width: 100, height: 100))
        case .separator:
            return CGSize(width: proposal.width ?? 100, height: 1)
        case .image:
            let natural = handle.imageNaturalSize
            return handle.imageResizable ? proposal.resolved(natural) : natural
        case .datePicker:
            // A CalendarDatePicker stretches, so guarantee a usable compact-field size regardless of what
            // its (stretch-driven) desired size reports for an unconstrained proposal.
            try? handle.element.measure(WindowsFoundation.Size(width: Float.infinity, height: Float.infinity))
            let desired = handle.element.desiredSize
            return CGSize(width: Swift.max(Double(desired.width), 240), height: Swift.max(Double(desired.height), 32))
        default:
            break
        }
        // Intrinsic size: measure the element unconstrained, then read its desired size.
        let availW = proposal.width.map { Float($0) } ?? Float.infinity
        let availH = proposal.height.map { Float($0) } ?? Float.infinity
        try? handle.element.measure(WindowsFoundation.Size(width: availW, height: availH))
        let desired = handle.element.desiredSize
        var w = Double(desired.width), h = Double(desired.height)
        if w <= 0 { w = Double(proposal.width ?? 0) }
        if handle.flexibleWidth, let pw = proposal.width, pw.isFinite {
            w = Swift.max(pw, w)
        }
        return CGSize(width: w, height: h)
    }

    public func sizeOf(_ handle: WinUIWidget) -> CGSize {
        if let stamped = handle.stampedSize { return stamped }
        let w = handle.element.actualWidth, h = handle.element.actualHeight
        return CGSize(width: w, height: h)
    }

    // MARK: - Shape drawing

    private func redrawShape(_ handle: WinUIWidget, _ rect: CGRect) {
        guard let path = handle.element as? WinUI.Path, let spec = handle.shapeSpec else { return }
        path.data = WinUIShapeBuilder.geometry(for: spec.path(rect))
        path.fill = spec.fill.map(Self.brush)
        if let stroke = spec.stroke {
            path.stroke = Self.brush(stroke)
            path.strokeThickness = Double(spec.lineWidth)
        } else {
            path.stroke = nil
        }
        // Center-anchored offset / rotation / scale, the SwiftUI transform order.
        let transform = WinUI.CompositeTransform()
        transform.centerX = Double(rect.width / 2)
        transform.centerY = Double(rect.height / 2)
        transform.translateX = Double(spec.offset.width)
        transform.translateY = Double(spec.offset.height)
        transform.rotation = spec.rotation.degrees
        transform.scaleX = Double(spec.scaleX)
        transform.scaleY = Double(spec.scaleY)
        path.renderTransform = transform
    }

    // MARK: - Window + run loop

    public func run(title: String, onReady: @escaping @MainActor (WinUIWidget) -> Void) {
        installWinUIMainExecutor()  // route hopTask onto the XAML/Win32 message loop

        let window = WinUI.Window()
        window.title = title
        let root = WinUI.Canvas()
        window.content = root
        self.window = window
        self.rootCanvas = root

        // Re-run the layout engine whenever the content area resizes.
        let sizeCleanup = root.sizeChanged.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated { self?.relayoutHandler?() }
        }
        let container = WinUIWidget(root, kind: .window, panel: root)
        container.cleanups.append(sizeCleanup)

        onReady(container)

        try? window.activate()
        // NOTE: control returns to the caller (`onLaunched`); the XAML `Application` owns the message loop.
    }

    public func openWindow(title: String, onReady: @escaping @MainActor (WinUIWidget) -> Void) {
        let window = WinUI.Window()
        window.title = title
        let root = WinUI.Canvas()
        window.content = root
        let container = WinUIWidget(root, kind: .window, panel: root)
        onReady(container)
        try? window.activate()
        secondaryWindows.append(window)
    }

    public func contentSize() -> CGSize {
        if let root = rootCanvas, root.actualWidth > 0, root.actualHeight > 0 {
            return CGSize(width: root.actualWidth, height: root.actualHeight)
        }
        if let bounds = window?.bounds, bounds.width > 0, bounds.height > 0 {
            return CGSize(width: Double(bounds.width), height: Double(bounds.height))
        }
        return CGSize(width: 820, height: 760)
    }

    public func setRelayoutHandler(_ handler: @escaping @MainActor () -> Void) {
        relayoutHandler = handler
    }

    public func scheduleOnMainThread(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    public func setColorScheme(_ colorScheme: ColorScheme?) {
        let theme: WinUI.ElementTheme
        switch colorScheme {
        case .dark: theme = .dark
        case .light: theme = .light
        case nil: theme = .default
        }
        rootCanvas?.requestedTheme = theme
    }

    public func setToolbar(_ items: [ToolbarItemSpec]) {
        // WinUI windows have no system toolbar; HopUI's toolbar items would need in-window chrome. The demo
        // remains fully usable without it (appearance toggles via the menu / system theme), so this is a
        // deliberate MVP no-op rather than a crash.
    }

    public func setMenu(_ menus: [MenuSpec]) {
        // Likewise, a WinUI window has no native menu bar; standard edit commands are handled by the focused
        // TextBox/PasswordBox natively. A MenuBar control could host these in a future iteration.
    }

    // MARK: - Conversions

    static func uwpColor(_ color: HopUI.Color) -> UWP.Color {
        func channel(_ v: Double) -> UInt8 { UInt8(Swift.max(0, Swift.min(255, (v * 255).rounded()))) }
        return UWP.Color(a: channel(color.opacity), r: channel(color.red), g: channel(color.green), b: channel(color.blue))
    }

    static func brush(_ color: HopUI.Color) -> WinUI.SolidColorBrush {
        WinUI.SolidColorBrush(uwpColor(color))
    }

    // WinRT DateTime is 100-ns ticks since 1601-01-01 (UTC); Foundation Date is seconds since 1970.
    private static let winrtEpochOffsetSeconds: Double = 11_644_473_600
    static func date(from dt: WindowsFoundation.DateTime) -> Date {
        Date(timeIntervalSince1970: Double(dt.universalTime) / 10_000_000 - winrtEpochOffsetSeconds)
    }
    static func dateTime(from date: Date) -> WindowsFoundation.DateTime {
        WindowsFoundation.DateTime(
            universalTime: Int64((date.timeIntervalSince1970 + winrtEpochOffsetSeconds) * 10_000_000))
    }

    // Date/time composition for the split CalendarDatePicker + TimePicker (all UTC-relative, matching the
    // tick math above): `timeOfDay` is the seconds since UTC midnight; `compose` rebuilds a Date from one
    // value's day and another's time-of-day, so editing one control preserves the other's component.
    private static let secondsPerDay: Double = 86_400
    static func timeOfDay(_ date: Date) -> Double {
        let t = date.timeIntervalSince1970
        return t - (t / secondsPerDay).rounded(.down) * secondsPerDay
    }
    static func compose(day: Date, secondsIntoDay: Double) -> Date {
        let dayStart = (day.timeIntervalSince1970 / secondsPerDay).rounded(.down) * secondsPerDay
        return Date(timeIntervalSince1970: dayStart + secondsIntoDay)
    }

    static func fontWeight(_ weight: HopUI.Font.Weight) -> UWP.FontWeight {
        UWP.FontWeight(weight: UInt16(weight.cssValue))
    }
}
