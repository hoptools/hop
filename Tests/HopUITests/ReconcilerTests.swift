// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI
import Observation

/// A toolkit that records every operation and never opens a window, so the full
/// view-graph → reconciler → toolkit pipeline can be tested headlessly.
@MainActor
final class MockWidget {
    let kind: WidgetKey
    var text: String?
    var title: String?
    var value: String?
    var doubleValue: Double?
    var boolValue: Bool?
    var action: (@MainActor () -> Void)?
    var onChange: (@MainActor (String) -> Void)?
    var onChangeDouble: (@MainActor (Double) -> Void)?
    var onChangeBool: (@MainActor (Bool) -> Void)?
    var listSpec: ListSpec?
    var foregroundColor: Color?
    var backgroundColor: Color?
    var font: Font?
    var fontWeight: Font.Weight?
    var axLabel: String?
    var axValue: String?
    var axHint: String?
    var axIdentifier: String?
    var axHidden: Bool?
    var axTraits: AccessibilityTraits?
    var shapeSpec: ShapeSpec?
    var menu: MenuContent?
    var picker: PickerSpec?
    var pickerStyleName: String?   // which Picker style renderer created this widget (component-system tests)
    var datePicker: DatePickerSpec?
    var colorPicker: ColorPickerSpec?
    var fileImporter: FileImporterSpec?
    var fileExporter: FileExporterSpec?
    var outline: OutlineSpec?
    var imageSpec: ImageSpec?
    var tabSpec: TabSpec?
    var progressValue: Double?
    var hasProgress = false
    var frame: CGRect?  // set by the layout engine via setFrame
    var scrollHandler: (@MainActor (CGSize) -> Void)?  // wired for .scroll widgets; tests invoke to scroll
    // Live child order, maintained by the toolkit's insert/move/remove so tests can assert ordering
    // and handle reuse (object identity) across reconciliation.
    var children: [MockWidget] = []
    init(kind: WidgetKey) { self.kind = kind }
}

@MainActor
final class MockToolkit: AppToolkit {
    typealias Handle = MockWidget

    private(set) var ops: [String] = []
    private(set) var widgets: [MockWidget] = []

    func clearOps() { ops.removeAll() }
    var makeCount: Int { ops.filter { $0.hasPrefix("make:") }.count }

    // MARK: - Open component system
    static let toolkitID = ToolkitID.mock
    let components = ComponentRegistry<MockWidget>()
    init() { registerBuiltinComponents() }

    func realize(_ component: any WidgetComponent) -> MockWidget {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.make(component) }
        if let widget = component.makeNative(Self.toolkitID) as? MockWidget {
            widgets.append(widget); ops.append("make:selfhosted"); return widget   // decoupled, no registered renderer
        }
        let widget = MockWidget(kind: .vstack); widgets.append(widget); ops.append("make:placeholder"); return widget
    }
    func updateComponent(_ handle: MockWidget, _ component: any WidgetComponent) {
        if let renderer = components.renderer(for: component.widgetKey) { renderer.update(handle, component); return }
        component.updateNative(handle, Self.toolkitID)
    }
    func measureComponent(_ handle: MockWidget, _ component: any WidgetComponent, _ proposal: ProposedViewSize) -> CGSize {
        if let renderer = components.renderer(for: component.widgetKey) { return renderer.measure(handle, component, proposal) }
        switch component.role {
        case .fill, .native: return proposal.resolved(.zero)
        default: return measure(handle, proposal)
        }
    }
    func didInsertChildren(_ handle: MockWidget, _ component: any WidgetComponent) {
        components.renderer(for: component.widgetKey)?.afterChildren?(handle, component)
    }
    private func registerBuiltinComponents() {
        // Leaf widgets: delegate to the legacy makeWidget/configure so existing op-log assertions hold.
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
        // Layout containers + layout-special layers — empty native widget; the engine drives the rest.
        let containerKinds: [WidgetKey] = [
            .vstack, .hstack, .zstack, .groupBox,
            .scroll, .geometry, .lazyStack, .spacer,
        ]
        for key in containerKinds {
            components.register(.init(
                make: { [unowned self] _ in makeNativeWidget(key) },
                update: { _, _ in },
                measure: { [unowned self] h, _, p in measure(h, p) }
            ), for: key)
        }
        // Native composites (List/OutlineGroup/SplitView/TabView).
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
        // Spec-carrying leaves (DatePicker/ColorPicker/Menu) — delegate to the legacy configure path.
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

        // Picker: one renderer per style, each producing a distinguishable mock widget so tests can assert
        // recreate-on-style-change (makeCount) and which native path was taken (pickerStyleName).
        for style in PickerStyle.allCases {
            components.register(.init(
                make: { [unowned self] component in
                    let widget = MockWidget(kind: .picker)
                    widgets.append(widget)
                    ops.append("make:picker.\(style.rawValue)")
                    widget.pickerStyleName = style.rawValue
                    if let spec = (component as? PickerComponent)?.spec { configurePicker(widget, spec) }
                    return widget
                },
                update: { [unowned self] handle, component in
                    if let spec = (component as? PickerComponent)?.spec { configurePicker(handle, spec) }
                },
                measure: { [unowned self] handle, _, proposal in measure(handle, proposal) }
            ), for: .picker(style))
        }
    }

    private func applyLeaf(_ handle: MockWidget, _ component: any WidgetComponent) {
        guard let leaf = component as? PrimitiveLeafComponent else { return }
        configure(handle, leaf.patch)
        setAction(handle, leaf.action)
        setTextHandler(handle, leaf.onChange)
        setValueHandler(handle, leaf.onChangeDouble)
        setBoolHandler(handle, leaf.onChangeBool)
    }

    func makeNativeWidget(_ key: WidgetKey) -> MockWidget {
        ops.append("make:\(key.rawValue)")
        let widget = MockWidget(kind: key)
        widgets.append(widget)
        return widget
    }

    func configure(_ handle: MockWidget, _ patch: WidgetPatch) {
        if let text = patch.text { ops.append("text:\(text)"); handle.text = text }
        if let title = patch.title { ops.append("title:\(title)"); handle.title = title }
        if let value = patch.value { ops.append("value:\(value)"); handle.value = value }
        if let doubleValue = patch.doubleValue { ops.append("double:\(doubleValue)"); handle.doubleValue = doubleValue }
        if let boolValue = patch.boolValue { ops.append("bool:\(boolValue)"); handle.boolValue = boolValue }
        if let fg = patch.foregroundColor { handle.foregroundColor = fg }
        if let bg = patch.backgroundColor { handle.backgroundColor = bg }
        if let font = patch.font { handle.font = font }
        if let weight = patch.fontWeight { handle.fontWeight = weight }
        if let label = patch.accessibilityLabel { handle.axLabel = label }
        if let value = patch.accessibilityValue { handle.axValue = value }
        if let hint = patch.accessibilityHint { handle.axHint = hint }
        if let identifier = patch.accessibilityIdentifier { handle.axIdentifier = identifier }
        if let hidden = patch.accessibilityHidden { handle.axHidden = hidden }
        if let traits = patch.accessibilityTraits { handle.axTraits = traits }
        // Progress: kind tells us it's a bar; a nil progressValue means indeterminate.
        if handle.kind == .progress { handle.hasProgress = true; handle.progressValue = patch.progressValue }
    }

    func insert(_ child: MockWidget, into parent: MockWidget, at index: Int) {
        ops.append("insert:\(index)")
        parent.children.insert(child, at: Swift.min(index, parent.children.count))
    }
    func move(_ child: MockWidget, in parent: MockWidget, to index: Int) {
        ops.append("move:\(index)")
        parent.children.removeAll { $0 === child }
        parent.children.insert(child, at: Swift.min(index, parent.children.count))
    }
    func remove(_ child: MockWidget, from parent: MockWidget) {
        ops.append("remove")
        parent.children.removeAll { $0 === child }
    }
    var moveCount: Int { ops.filter { $0.hasPrefix("move:") }.count }
    var removeCount: Int { ops.filter { $0 == "remove" }.count }
    func setAction(_ handle: MockWidget, _ action: (@MainActor () -> Void)?) { handle.action = action }
    func setTextHandler(_ handle: MockWidget, _ handler: (@MainActor (String) -> Void)?) { handle.onChange = handler }
    func setValueHandler(_ handle: MockWidget, _ handler: (@MainActor (Double) -> Void)?) { handle.onChangeDouble = handler }
    func setBoolHandler(_ handle: MockWidget, _ handler: (@MainActor (Bool) -> Void)?) { handle.onChangeBool = handler }
    func configureList(_ handle: MockWidget, _ spec: ListSpec) { ops.append("list:\(spec.count)"); handle.listSpec = spec }
    func configureShape(_ handle: MockWidget, _ spec: ShapeSpec) { ops.append("shape"); handle.shapeSpec = spec }
    func configureMenu(_ handle: MockWidget, _ menu: MenuContent) { ops.append("menu:\(menu.label)"); handle.menu = menu }
    func configurePicker(_ handle: MockWidget, _ spec: PickerSpec) { ops.append("picker:\(spec.options.count)"); handle.picker = spec }
    func configureDatePicker(_ handle: MockWidget, _ spec: DatePickerSpec) { ops.append("datePicker:\(spec.components.rawValue)"); handle.datePicker = spec }
    func configureColorPicker(_ handle: MockWidget, _ spec: ColorPickerSpec) { ops.append("colorPicker:\(spec.supportsOpacity)"); handle.colorPicker = spec }
    func configureFileImporter(_ handle: MockWidget, _ spec: FileImporterSpec) { handle.fileImporter = spec; if spec.isPresented { ops.append("fileImporter") } }
    func configureFileExporter(_ handle: MockWidget, _ spec: FileExporterSpec) { handle.fileExporter = spec; if spec.isPresented { ops.append("fileExporter") } }
    func configureOutline(_ handle: MockWidget, _ spec: OutlineSpec) { ops.append("outline:\(spec.roots.count)"); handle.outline = spec }
    func configureImage(_ handle: MockWidget, _ spec: ImageSpec) {
        let kind: String
        switch spec.source {
        case .named(let n, _): kind = "named:\(n)"
        case .system(let n): kind = "system:\(n)"
        case .file(let u): kind = "file:\(u.lastPathComponent)"
        case .data: kind = "data"
        }
        ops.append("image:\(kind)")
        handle.imageSpec = spec
    }
    func configureTabs(_ handle: MockWidget, _ spec: TabSpec) {
        ops.append("tabs:\(spec.titles.joined(separator: ","))@\(spec.selectedIndex)")
        handle.tabSpec = spec
    }

    // Framework-owned layout: record frames; provide deterministic leaf sizes so layout is assertable.
    func setFrame(_ handle: MockWidget, _ rect: CGRect) { handle.frame = rect }
    func sizeOf(_ handle: MockWidget) -> CGSize { handle.frame?.size ?? .zero }
    func setScrollHandler(_ handle: MockWidget, _ handler: (@MainActor (CGSize) -> Void)?) { handle.scrollHandler = handler }
    /// Identifying labels of widgets actually measured through the toolkit (cache misses), for asserting
    /// incremental layout: an unchanged subtree's leaves are NOT re-measured.
    private(set) var measuredLabels: [String] = []
    func clearMeasured() { measuredLabels.removeAll() }
    func measure(_ handle: MockWidget, _ proposal: ProposedViewSize) -> CGSize {
        if let label = handle.text ?? handle.title { measuredLabels.append(label) }
        switch handle.kind {
        case .label: return CGSize(width: CGFloat((handle.text ?? "").count) * 8 + 8, height: 20)
        case .button: return CGSize(width: CGFloat((handle.title ?? "").count) * 8 + 16, height: 24)
        case .textField, .secureField: return CGSize(width: 120, height: 24)
        case .slider: return CGSize(width: 100, height: 20)
        case .toggle: return CGSize(width: 40, height: 22)
        case .progress: return CGSize(width: 100, height: 8)
        case .shape: return proposal.resolved(CGSize(width: 10, height: 10))  // shapes are greedy
        case .image:
            let natural = CGSize(width: 30, height: 20)  // deterministic natural size for layout assertions
            return (handle.imageSpec?.resizable ?? false) ? proposal.resolved(natural) : natural
        default: return CGSize(width: proposal.width ?? 40, height: proposal.height ?? 20)
        }
    }
    func contentSize() -> CGSize { CGSize(width: 800, height: 600) }
    private(set) var relayoutHandler: (@MainActor () -> Void)?
    func setRelayoutHandler(_ handler: @escaping @MainActor () -> Void) { relayoutHandler = handler }

    private(set) var toolbarItems: [ToolbarItemSpec] = []
    func setToolbar(_ items: [ToolbarItemSpec]) { toolbarItems = items }

    private(set) var menus: [MenuSpec] = []
    func setMenu(_ menus: [MenuSpec]) { self.menus = menus }

    private(set) var rootContainer: MockWidget?
    func run(title: String, onReady: @escaping @MainActor (MockWidget) -> Void) {
        let container = MockWidget(kind: .window)
        rootContainer = container
        onReady(container)
    }

    /// All text/title in the CURRENT (live) widget tree, for navigation assertions that must reflect
    /// what is actually mounted now (unlike `widgets`, which is append-only).
    func liveLabels() -> [String] {
        var out: [String] = []
        func walk(_ widget: MockWidget) {
            if let text = widget.text { out.append(text) }
            if let title = widget.title { out.append(title) }
            for child in widget.children { walk(child) }
        }
        if let rootContainer { walk(rootContainer) }
        return out
    }

    private(set) var openedWindows: [String] = []
    func openWindow(title: String, onReady: @escaping @MainActor (MockWidget) -> Void) {
        openedWindows.append(title)
        onReady(MockWidget(kind: .window))
    }

    private(set) var appliedColorScheme: ColorScheme?
    func setColorScheme(_ colorScheme: ColorScheme?) { appliedColorScheme = colorScheme }

    // Deferred main-thread work (the observation re-render). Tests run it explicitly via drainMainThread().
    private var pendingMain: [@MainActor () -> Void] = []
    func scheduleOnMainThread(_ work: @escaping @MainActor () -> Void) { pendingMain.append(work) }
    func drainMainThread() {
        let pending = pendingMain
        pendingMain = []
        for work in pending { work() }
    }
}

@MainActor
private struct TestCounter: View {
    @State var count = 0
    @State var name = ""
    var body: some View {
        VStack {
            Text("Count: \(count)")
            Button("inc") { count += 1 }
            Slider(value: Binding(get: { Double(count) }, set: { count = Int($0.rounded()) }), in: 0...10)
            TextField("name", text: $name)
            Text("Hello, \(name)!")
        }
    }
}

@MainActor @Suite struct ReconcilerTests {
    @Test func testStateMutationProducesMinimalUpdate() throws {
        let toolkit = MockToolkit()
        runHopApp(TestCounter(), toolkit: toolkit, title: "test")

        // Initial mount renders the label at its starting value and creates real widgets.
        #expect(toolkit.widgets.contains { $0.text == "Count: 0" })
        #expect(toolkit.makeCount > 0)

        toolkit.clearOps()

        // Drive the button's action exactly as a real click would.
        let button = try #require(toolkit.widgets.first { $0.kind == .button })
        button.action?()
        toolkit.drainMainThread()

        // The label now reflects the new state...
        #expect(toolkit.widgets.contains { $0.text == "Count: 1" })
        // ...and the reconciler reused existing widgets (no new ones) and updated only the label.
        #expect(toolkit.makeCount == 0)
        #expect(toolkit.ops.contains("text:Count: 1"))
    }

    @Test func testTextFieldEditUpdatesBoundStateAndDependentLabel() throws {
        let toolkit = MockToolkit()
        runHopApp(TestCounter(), toolkit: toolkit, title: "test")

        #expect(toolkit.widgets.contains { $0.text == "Hello, !" })
        toolkit.clearOps()

        // Simulate the user typing into the field exactly as the toolkit's change handler would.
        let field = try #require(toolkit.widgets.first { $0.kind == .textField })
        field.onChange?("Ada")
        toolkit.drainMainThread()

        // The label bound to the same @State updates, and no widgets were recreated.
        #expect(toolkit.widgets.contains { $0.text == "Hello, Ada!" })
        #expect(toolkit.makeCount == 0)
    }

    @Test func testSliderSharesCountStateWithButtonAndLabel() throws {
        let toolkit = MockToolkit()
        runHopApp(TestCounter(), toolkit: toolkit, title: "test")
        toolkit.clearOps()

        // Dragging the slider updates the same @State the counter button and label use.
        let slider = try #require(toolkit.widgets.first { $0.kind == .slider })
        slider.onChangeDouble?(5)
        toolkit.drainMainThread()

        #expect(toolkit.widgets.contains { $0.text == "Count: 5" })
        #expect(toolkit.makeCount == 0)

        // And the button still drives the same state, now visible on the slider.
        let button = try #require(toolkit.widgets.first { $0.kind == .button })
        button.action?()
        toolkit.drainMainThread()
        #expect(toolkit.widgets.contains { $0.text == "Count: 6" })
        #expect(toolkit.widgets.first { $0.kind == .slider }?.doubleValue == 6)
    }
}

private struct ListSelectionView: View {
    @State var selection: Int? = nil
    var body: some View {
        HStack {
            List(0 ..< 100_000, id: \.self, selection: $selection) { Text("Row \($0)") }
            Text(selection.map { "Selected Row \($0)" } ?? "No selection")
        }
    }
}

@MainActor @Suite struct ListTests {
    @Test func testListIsLazyAndSelectionBindsToState() throws {
        let toolkit = MockToolkit()
        runHopApp(ListSelectionView(), toolkit: toolkit, title: "test")

        let list = try #require(toolkit.widgets.first { $0.kind == .list })
        let spec = try #require(list.listSpec)

        // The whole 100k-row list is one widget — rows are fetched lazily, not materialized.
        #expect(spec.count == 100_000)
        #expect(toolkit.widgets.filter { $0.kind == .label }.count == 1) // only the detail label
        #expect(spec.rowText(99_999) == "Row 99999")
        #expect(toolkit.widgets.contains { $0.text == "No selection" })

        // Selecting a row updates the bound @State, which the detail label reflects.
        toolkit.clearOps()
        list.listSpec?.onSelect(42)
        toolkit.drainMainThread()
        #expect(toolkit.widgets.contains { $0.text == "Selected Row 42" })
        #expect(toolkit.makeCount == 0) // no new widgets created for the update
    }
}

private struct SplitDemo: View {
    @State var selection: Int? = nil
    var body: some View {
        NavigationSplitView {
            List(0 ..< 50, id: \.self, selection: $selection) { Text("Row \($0)") }
        } detail: {
            Text(selection.map { "Selected \($0)" } ?? "None")
        }
    }
}

private struct ToolbarDemo: View {
    @State var count = 0
    var body: some View {
        Text("Count: \(count)")
            .toolbar {
                Button("Inc") { count += 1 }
                Text("Title")
            }
    }
}

@MainActor @Suite struct StandardMenuTests {
    @Test func testStandardMenusInstalledAutomatically() throws {
        let toolkit = MockToolkit()
        runHopApp(Text("hi"), toolkit: toolkit, title: "test")

        // HopUI installs the standard menu bar automatically — no app code required.
        #expect(toolkit.menus.map { $0.title } == ["File", "Edit", "View", "Window", "Help"])

        let edit = try #require(toolkit.menus.first { $0.title == "Edit" })
        let commands = edit.items.compactMap { item -> String? in
            if case .command(let title, _) = item.kind { return title }
            return nil
        }
        #expect(commands == ["Cut", "Copy", "Paste", "Select All"])
    }
}

@MainActor @Suite struct ToolbarTests {
    @Test func testToolbarItemsAndButtonAction() throws {
        let toolkit = MockToolkit()
        runHopApp(ToolbarDemo(), toolkit: toolkit, title: "test")

        #expect(toolkit.toolbarItems.count == 2)
        guard case .button(let title, let action) = toolkit.toolbarItems[0].kind else {
            Issue.record("first toolbar item should be a button"); return
        }
        #expect(title == "Inc")
        if case .text(let string) = toolkit.toolbarItems[1].kind {
            #expect(string == "Title")
        } else {
            Issue.record("second toolbar item should be text")
        }

        // A toolbar button mutates app state, which re-renders the content.
        action()
        toolkit.drainMainThread()
        #expect(toolkit.widgets.contains { $0.text == "Count: 1" })
    }
}

// MARK: - Accessibility modifiers

private struct A11yDemo: View {
    var body: some View {
        VStack {
            Text("★★★★☆")
                .accessibilityLabel("Rating")
                .accessibilityValue("4 out of 5 stars")
            Button("Save") { }
                .accessibilityLabel("Save document")
                .accessibilityHint("Writes your changes to disk")
            Text("decorative")
                .accessibilityHidden(true)
            Text("Heading")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("the-heading")
        }
    }
}

@MainActor @Suite struct AccessibilityTests {
    @Test func testAccessibilityModifiersRecordedOnNodes() throws {
        let toolkit = MockToolkit()
        runHopApp(A11yDemo(), toolkit: toolkit, title: "test")

        // Label overrides the visible text; value is separate.
        let rating = try #require(toolkit.widgets.first { $0.axLabel == "Rating" })
        #expect(rating.text == "★★★★☆")            // the visible content is unchanged
        #expect(rating.axValue == "4 out of 5 stars")

        // A button carries a label + hint.
        let save = try #require(toolkit.widgets.first { $0.kind == .button })
        #expect(save.axLabel == "Save document")
        #expect(save.axHint == "Writes your changes to disk")

        // Hidden + traits + identifier.
        #expect(toolkit.widgets.contains { $0.axHidden == true })
        let heading = try #require(toolkit.widgets.first { $0.axIdentifier == "the-heading" })
        #expect(heading.axTraits == .isHeader)
    }
}

// MARK: - Color scheme (preferredColorScheme / environment(\.colorScheme) / .commands menu)

@Observable private final class SchemeModel {
    var scheme: ColorScheme = .light
    func toggle() { scheme = scheme == .dark ? .light : .dark }
}

private struct SchemeChild: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Text("scheme:\(scheme == .dark ? "dark" : "light")") }
}

private struct SchemeRoot: View {
    @Environment(SchemeModel.self) private var model
    var body: some View {
        SchemeChild()
            .preferredColorScheme(model.scheme)
            .environment(\.colorScheme, model.scheme)
    }
}

private struct SchemeApp: App {
    let model = SchemeModel()
    var body: some Scene {
        WindowGroup {
            SchemeRoot().environment(model)
        }
        .commands {
            CommandMenu("Appearance") {
                Button("Toggle Light / Dark") { model.toggle() }
            }
        }
    }
}

@MainActor @Suite struct ColorSchemeTests {
    @Test func testPreferredColorSchemeAndMenuToggle() throws {
        let toolkit = MockToolkit()
        runApp(SchemeApp(), toolkit: toolkit)

        // Initial: light. The window appearance is applied and @Environment(\.colorScheme) reflects it.
        #expect(toolkit.appliedColorScheme == .light)
        #expect(toolkit.liveLabels().contains("scheme:light"))

        // The app's .commands contributed an "Appearance" menu (merged into the menu bar after "View").
        let appearance = try #require(toolkit.menus.first { $0.title == "Appearance" })
        guard case .button(_, let toggle) = try #require(appearance.items.first).kind else {
            Issue.record("expected a button command"); return
        }

        // Toggling from the menu flips the model; the @Observable re-render applies dark to the window
        // and updates the environment value.
        toggle()
        toolkit.drainMainThread()
        #expect(toolkit.appliedColorScheme == .dark)
        #expect(toolkit.liveLabels().contains("scheme:dark"))
    }
}

// MARK: - Text styling modifiers

private struct StyleDemo: View {
    var body: some View {
        VStack {
            Text("plain")
            Text("styled").font(.system(size: 22, weight: .bold)).foregroundStyle(.red)
            Text("weighted").fontWeight(.bold)
            Text("bg").background(.yellow)
            VStack {
                Text("inherited")
            }
            .font(.system(size: 10))
            .foregroundStyle(.blue)
        }
    }
}

@MainActor @Suite struct TextStyleTests {
    @Test func testStyleModifiersApplyAndInherit() throws {
        let toolkit = MockToolkit()
        runHopApp(StyleDemo(), toolkit: toolkit, title: "test")

        let plain = try #require(toolkit.widgets.first { $0.text == "plain" })
        #expect(plain.font == nil)
        #expect(plain.foregroundColor == nil)

        let styled = try #require(toolkit.widgets.first { $0.text == "styled" })
        #expect(styled.font?.size == 22)
        #expect(styled.font?.weight == .bold)
        #expect(styled.foregroundColor == .red)

        // .fontWeight alone is a weight override that doesn't introduce a full font.
        let weighted = try #require(toolkit.widgets.first { $0.text == "weighted" })
        #expect(weighted.font == nil)
        #expect(weighted.fontWeight == .bold)

        // `.background` wraps the view in a container painted with the color (so it covers any padding/
        // frame, matching SwiftUI) — the yellow is on the wrapping container, with the text as its child.
        let bgContainer = try #require(toolkit.widgets.first { $0.backgroundColor == .yellow })
        #expect(bgContainer.kind == .zstack)
        #expect(bgContainer.children.contains { $0.text == "bg" })

        // Font and foreground style are environment-inherited from the enclosing VStack.
        let inherited = try #require(toolkit.widgets.first { $0.text == "inherited" })
        #expect(inherited.font?.size == 10)
        #expect(inherited.foregroundColor == .blue)
    }
}

// MARK: - Navigation (master-detail selection + NavigationStack push/pop)

private enum TestPG: CaseIterable, Hashable {
    case a, b
    var title: String { self == .a ? "PageA" : "PageB" }
}

private struct NavDemo: View {
    @State var selection: TestPG? = .a
    @State var path: [String] = []
    var body: some View {
        NavigationSplitView {
            List(TestPG.allCases, id: \.self, selection: Binding(
                get: { selection }, set: { selection = $0; path = [] })) { Text($0.title) }
        } detail: {
            NavigationStack(path: $path) {
                content
                    .navigationTitle(selection?.title ?? "none")
                    .navigationDestination(for: String.self) { _ in Text("DeepPage").navigationTitle("Deep") }
            }
        }
    }

    @ViewBuilder var content: some View {
        if selection == .a {
            VStack { Text("BodyA"); NavigationLink("go", value: "deep") }
        } else if selection == .b {
            Text("BodyB")
        } else {
            Text("none")
        }
    }
}

@MainActor @Suite struct NavigationTests {
    @Test func testSidebarSelectionAndStackPushPop() throws {
        let toolkit = MockToolkit()
        runHopApp(NavDemo(), toolkit: toolkit, title: "test")

        // Initial: PageA selected → its body and title show; PageB's body does not.
        #expect(toolkit.liveLabels().contains("BodyA"))
        #expect(toolkit.liveLabels().contains("PageA"))   // navigation title
        #expect(!(toolkit.liveLabels().contains("BodyB")))

        // Master-detail navigation: selecting B in the sidebar navigates the detail to B. A List in the
        // NavigationSplitView's leading column renders as a `.sidebarList` (source-list styling).
        let list = try #require(toolkit.widgets.first { $0.kind == .sidebarList })
        list.listSpec?.onSelect(1)
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("BodyB"))
        #expect(toolkit.liveLabels().contains("PageB"))
        #expect(!(toolkit.liveLabels().contains("BodyA")))

        // Back to A, then push via NavigationLink → the destination replaces the root, Back appears.
        list.listSpec?.onSelect(0)
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("BodyA"))
        try #require(toolkit.widgets.first { $0.kind == .button && $0.title == "go" }).action?()
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("DeepPage"))
        #expect(toolkit.liveLabels().contains("Deep"))    // pushed view's navigation title
        #expect(toolkit.liveLabels().contains("‹ Back"))
        #expect(!(toolkit.liveLabels().contains("BodyA")))

        // Pop via Back → root view restored, destination gone.
        try #require(toolkit.widgets.first { $0.kind == .button && $0.title == "‹ Back" }).action?()
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("BodyA"))
        #expect(!(toolkit.liveLabels().contains("DeepPage")))

        // Selecting a different playground resets the navigation path (no stale pushed page).
        list.listSpec?.onSelect(0)
        toolkit.drainMainThread()
        #expect(!(toolkit.liveLabels().contains("DeepPage")))
    }
}

// MARK: - @Observable through @Environment

@Observable private final class CounterModel {
    var n = 0
}

private struct EnvProducer: View {
    @State var model = CounterModel()
    var body: some View {
        VStack {
            Text("parent: \(model.n)")
            EnvConsumer()
        }
        .environment(model)
    }
}

private struct EnvConsumer: View {
    @Environment(CounterModel.self) private var model
    var body: some View {
        VStack {
            Text("child: \(model.n)")
            Button("inc") { model.n += 1 }
        }
    }
}

@MainActor @Suite struct ObservableEnvironmentTests {
    @Test func testObservableInjectedThroughEnvironmentIsReadAndWritten() throws {
        let toolkit = MockToolkit()
        runHopApp(EnvProducer(), toolkit: toolkit, title: "test")

        // The object is visible in the descendant (via @Environment) and the ancestor (which owns it).
        #expect(toolkit.widgets.contains { $0.text == "parent: 0" })
        #expect(toolkit.widgets.contains { $0.text == "child: 0" })

        toolkit.clearOps()
        // Writing through the environment-provided instance, in the child view.
        try #require(toolkit.widgets.first { $0.title == "inc" }).action?()
        // The @Observable mutation defers its re-render; run it.
        toolkit.drainMainThread()

        // Both views — child and parent — reflect the shared model, with no widgets rebuilt.
        #expect(toolkit.widgets.contains { $0.text == "child: 1" })
        #expect(toolkit.widgets.contains { $0.text == "parent: 1" })
        #expect(toolkit.makeCount == 0)
    }
}

// MARK: - Keyed identity & diffing

private struct KeyedListDemo: View {
    @State var items: [Int] = [1, 2, 3]
    var body: some View {
        VStack {
            ForEach(items, id: \.self) { item in
                Text("Item \(item)")
            }
            Button("reverse") { items = items.reversed() }
            Button("insertFront") { items.insert(0, at: 0) }
            Button("dropFirst") { if !items.isEmpty { items.removeFirst() } }
        }
    }
}

private struct KeyedFieldDemo: View {
    @State var ids: [Int] = [1, 2]
    @State var textRow1 = ""
    var body: some View {
        VStack {
            ForEach(ids, id: \.self) { id in
                TextField("row \(id)", text: id == 1 ? $textRow1 : .constant("other"))
            }
            Button("swap") { ids = ids.reversed() }
        }
    }
}

@MainActor @Suite struct KeyedDiffTests {
    @Test func testForEachReorderReusesRowWidgetsAndPreservesState() throws {
        let toolkit = MockToolkit()
        runHopApp(KeyedFieldDemo(), toolkit: toolkit, title: "test")
        let vstack = try #require(toolkit.widgets.first { $0.kind == .vstack })

        // Two text-field rows in order; the first is bound to row-1 state.
        #expect(vstack.children.filter { $0.kind == .textField }.count == 2)
        let field1 = try #require(vstack.children.first { $0.kind == .textField })

        // Type into row 1; its bound @State (and the widget's value) update in place.
        field1.onChange?("hello")
        toolkit.drainMainThread()
        #expect(field1.value == "hello")

        toolkit.clearOps()
        let swap = try #require(toolkit.widgets.first { $0.title == "swap" })
        swap.action?()
        toolkit.drainMainThread()

        // After reordering, the SAME row-1 widget is reused (no rebuild) and keeps its typed value;
        // it has simply moved to the second position.
        #expect(toolkit.makeCount == 0)
        #expect(toolkit.removeCount == 0)
        #expect(toolkit.moveCount > 0)
        #expect(vstack.children.contains { $0 === field1 })
        #expect(field1.value == "hello")
        #expect(vstack.children.firstIndex { $0 === field1 } == 1)
    }

    @Test func testForEachReorderEmitsOnlyMoves() throws {
        let toolkit = MockToolkit()
        runHopApp(KeyedListDemo(), toolkit: toolkit, title: "test")
        let vstack = try #require(toolkit.widgets.first { $0.kind == .vstack })
        #expect(vstack.children.compactMap { $0.text } == ["Item 1", "Item 2", "Item 3"])
        let middle = try #require(vstack.children.first { $0.text == "Item 2" })

        toolkit.clearOps()
        try #require(toolkit.widgets.first { $0.title == "reverse" }).action?()
        toolkit.drainMainThread()

        #expect(vstack.children.compactMap { $0.text } == ["Item 3", "Item 2", "Item 1"])
        #expect(toolkit.makeCount == 0)       // every row reused, none rebuilt
        #expect(toolkit.removeCount == 0)
        #expect(toolkit.moveCount > 0)
        #expect(vstack.children.contains { $0 === middle })  // same widget object
    }

    @Test func testForEachInsertIsMinimal() throws {
        let toolkit = MockToolkit()
        runHopApp(KeyedListDemo(), toolkit: toolkit, title: "test")
        let vstack = try #require(toolkit.widgets.first { $0.kind == .vstack })

        toolkit.clearOps()
        try #require(toolkit.widgets.first { $0.title == "insertFront" }).action?()
        toolkit.drainMainThread()

        #expect(vstack.children.compactMap { $0.text } == ["Item 0", "Item 1", "Item 2", "Item 3"])
        #expect(toolkit.makeCount == 1)    // only the new row is built
        #expect(toolkit.removeCount == 0)
        #expect(toolkit.moveCount == 0)    // existing rows shift via the insert, not moves
    }

    @Test func testForEachDeleteRemovesOnlyTheDroppedRow() throws {
        let toolkit = MockToolkit()
        runHopApp(KeyedListDemo(), toolkit: toolkit, title: "test")
        let vstack = try #require(toolkit.widgets.first { $0.kind == .vstack })

        toolkit.clearOps()
        try #require(toolkit.widgets.first { $0.title == "dropFirst" }).action?()
        toolkit.drainMainThread()

        #expect(vstack.children.compactMap { $0.text } == ["Item 2", "Item 3"])
        #expect(toolkit.makeCount == 0)
        #expect(toolkit.removeCount == 1)
        #expect(toolkit.moveCount == 0)
    }
}

private struct IDResetDemo: View {
    @State var token = 0
    var body: some View {
        VStack {
            Text("Tagged").id(token)
            Button("bump") { token += 1 }
        }
    }
}

private struct BranchDemo: View {
    @State var on = false
    var body: some View {
        VStack {
            if on {
                Text("ON")
            } else {
                Button("OFF") { }
            }
            Button("toggle") { on.toggle() }
        }
    }
}

@MainActor @Suite struct IdentityTests {
    @Test func testExplicitIDChangeRebuildsSubtree() throws {
        let toolkit = MockToolkit()
        runHopApp(IDResetDemo(), toolkit: toolkit, title: "test")
        let vstack = try #require(toolkit.widgets.first { $0.kind == .vstack })
        let before = try #require(vstack.children.first { $0.text == "Tagged" })

        toolkit.clearOps()
        try #require(toolkit.widgets.first { $0.title == "bump" }).action?()
        toolkit.drainMainThread()

        // Changing .id() gives the subtree a fresh identity: old widget removed, new one built.
        #expect(toolkit.makeCount == 1)
        #expect(toolkit.removeCount == 1)
        let after = try #require(vstack.children.first { $0.text == "Tagged" })
        #expect(!(before === after))
    }

    @Test func testConditionalBranchSwitchResetsIdentity() throws {
        let toolkit = MockToolkit()
        runHopApp(BranchDemo(), toolkit: toolkit, title: "test")
        let vstack = try #require(toolkit.widgets.first { $0.kind == .vstack })

        // The else arm (a Button) is shown first.
        #expect(vstack.children.first?.kind == .button)
        #expect(vstack.children.first?.title == "OFF")

        toolkit.clearOps()
        try #require(toolkit.widgets.first { $0.title == "toggle" }).action?()
        toolkit.drainMainThread()

        // Switching arms is a distinct identity (and kind), so the button is torn down and the text
        // built fresh — not reconciled in place.
        #expect(vstack.children.first?.kind == .label)
        #expect(vstack.children.first?.text == "ON")
        #expect(toolkit.makeCount >= 1)
        #expect(toolkit.removeCount >= 1)
    }
}

private struct WindowDemoApp: App {
    var body: some Scene {
        WindowGroup("Main Window") {
            Text("main content")
        }
        Window("About", id: "about") {
            Text("about content")
        }
    }
}

@MainActor @Suite struct WindowManagementTests {
    @Test func testRunAppMountsPrimaryAndOpenWindowPresentsSecondary() throws {
        let toolkit = MockToolkit()
        runApp(WindowDemoApp(), toolkit: toolkit)

        // The primary WindowGroup is mounted via the main loop; no secondary windows yet.
        #expect(toolkit.widgets.contains { $0.text == "main content" })
        #expect(toolkit.openedWindows.isEmpty)

        // openWindow(id:) (vended via the base environment) presents the registered "About" Window.
        let environment = try #require(GraphContext.current).read(try #require(GraphContext.viewGraph).baseEnvironment)
        environment.openWindow(id: "about")
        #expect(toolkit.openedWindows == ["About"])
        #expect(toolkit.widgets.contains { $0.text == "about content" })

        // An unknown id is a no-op.
        environment.openWindow(id: "missing")
        #expect(toolkit.openedWindows == ["About"])
    }
}

// MARK: - Shapes (Shape protocol, fill/stroke, frame, transforms, custom Path)

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

private struct ShapeDemo: View {
    var body: some View {
        VStack {
            Rectangle().fill(.red).frame(width: 40, height: 20)
            Circle().stroke(.blue, lineWidth: 3).frame(width: 30, height: 30)
            Triangle().frame(width: 50, height: 50)  // no explicit style → inherits foreground
            Capsule().fill(.green)
                .rotationEffect(.degrees(90))
                .offset(x: 5, y: -3)
                .scaleEffect(2)
        }
        .foregroundStyle(.purple)
    }
}

@MainActor @Suite struct ShapeTests {
    @Test func testBuiltInShapesFillStrokeAndFrame() throws {
        let toolkit = MockToolkit()
        runHopApp(ShapeDemo(), toolkit: toolkit, title: "test")

        // Four shape widgets were created.
        #expect(toolkit.widgets.filter { $0.kind == .shape }.count == 4)

        // Rectangle: red fill, fixed 40×20 (the layout engine sized it from `.frame`), and a single
        // native rect path element.
        let rect = try #require(toolkit.widgets.first { $0.shapeSpec?.fill == .red })
        #expect(rect.frame?.width == 40)
        #expect(rect.frame?.height == 20)
        #expect(rect.shapeSpec?.stroke == nil)
        let r = CGRect(x: 0, y: 0, width: 40, height: 20)
        #expect(rect.shapeSpec?.path(r).elements == [.rect(r)])

        // Circle: stroked (no fill), with the requested line width; its path is an inscribed ellipse.
        let circle = try #require(toolkit.widgets.first { $0.shapeSpec?.stroke == .blue })
        #expect(circle.shapeSpec?.fill == nil)
        #expect(circle.shapeSpec?.lineWidth == 3)
        let square = CGRect(x: 0, y: 0, width: 30, height: 30)
        #expect(circle.shapeSpec?.path(square).elements == [.ellipse(in: square)])
    }

    @Test func testBareShapeInheritsForegroundAndCustomPath() throws {
        let toolkit = MockToolkit()
        runHopApp(ShapeDemo(), toolkit: toolkit, title: "test")

        // A bare shape with no fill/stroke fills with the inherited foreground color (.purple here);
        // it is the only such shape, and the layout engine sized it to its 50×50 `.frame`.
        let triangle = try #require(toolkit.widgets.first { $0.shapeSpec?.fill == .purple })
        #expect(triangle.frame?.width == 50)
        #expect(triangle.frame?.height == 50)

        // The custom shape replays its Path verbatim.
        let r = CGRect(x: 0, y: 0, width: 50, height: 50)
        #expect(triangle.shapeSpec?.path(r).elements == [
            .move(to: CGPoint(x: 25, y: 0)),
            .line(to: CGPoint(x: 50, y: 50)),
            .line(to: CGPoint(x: 0, y: 50)),
            .closeSubpath,
        ])
    }

    @Test func testTransformModifiersAccumulateOnSpec() throws {
        let toolkit = MockToolkit()
        runHopApp(ShapeDemo(), toolkit: toolkit, title: "test")

        // Capsule: fill plus a chain of transforms, all gathered onto one shape spec.
        let capsule = try #require(toolkit.widgets.first { $0.shapeSpec?.fill == .green })
        #expect(capsule.shapeSpec?.rotation == .degrees(90))
        #expect(capsule.shapeSpec?.offset == CGSize(width: 5, height: -3))
        #expect(capsule.shapeSpec?.scaleX == 2)
        #expect(capsule.shapeSpec?.scaleY == 2)
    }
}

// MARK: - Drop-down menus (Menu, Picker, Divider, .tag)

private struct MenuDemo: View {
    @State var log = ""
    @State var choice = 2
    var body: some View {
        VStack {
            Menu("Actions") {
                Button("New") { log = "New" }
                Divider()
                Button("Save") { log = "Save" }
                Menu("Export") {
                    Button("PDF") { log = "PDF" }
                }
            }
            Text("log:\(log)")
            Picker("Number", selection: $choice) {
                Text("One").tag(1)
                Text("Two").tag(2)
                Text("Three").tag(3)
            }
            Text("choice:\(choice)")
        }
    }
}

@MainActor @Suite struct MenuTests {
    @Test func testMenuEntriesIncludeButtonsSeparatorsAndSubmenu() throws {
        let toolkit = MockToolkit()
        runHopApp(MenuDemo(), toolkit: toolkit, title: "test")

        let widget = try #require(toolkit.widgets.first { $0.kind == .menu })
        let menu = try #require(widget.menu)
        #expect(menu.label == "Actions")
        #expect(menu.entries.count == 4)  // New, ──, Save, Export▸

        guard case .button(let t0, let action0) = menu.entries[0] else { Issue.record("entry 0 should be a button"); return }
        #expect(t0 == "New")
        guard case .separator = menu.entries[1] else { Issue.record("entry 1 should be a separator"); return }
        guard case .button(let t2, _) = menu.entries[2] else { Issue.record("entry 2 should be a button"); return }
        #expect(t2 == "Save")
        guard case .submenu(let subTitle, let subEntries) = menu.entries[3] else { Issue.record("entry 3 should be a submenu"); return }
        #expect(subTitle == "Export")
        #expect(subEntries.count == 1)

        // A menu action mutates state, which re-renders the dependent label.
        action0()
        toolkit.drainMainThread()
        #expect(toolkit.widgets.contains { $0.text == "log:New" })
    }

    @Test func testPickerReflectsAndUpdatesSelectionBinding() throws {
        let toolkit = MockToolkit()
        runHopApp(MenuDemo(), toolkit: toolkit, title: "test")

        let widget = try #require(toolkit.widgets.first { $0.kind == .picker })
        let picker = try #require(widget.picker)
        #expect(picker.options == ["One", "Two", "Three"])
        #expect(picker.selectedIndex == 1)  // choice == 2 → tag 2 is at index 1
        #expect(toolkit.widgets.contains { $0.text == "choice:2" })

        // Selecting index 2 (tag 3) writes through the binding; the dependent label updates in place.
        toolkit.clearOps()
        picker.onSelect(2)
        toolkit.drainMainThread()
        #expect(toolkit.widgets.contains { $0.text == "choice:3" })
        #expect(toolkit.makeCount == 0)  // no widgets rebuilt for the selection change
    }
}

@MainActor @Suite struct NavigationSplitViewTests {
    @Test func testSidebarSelectionDrivesDetailPane() throws {
        let toolkit = MockToolkit()
        runHopApp(SplitDemo(), toolkit: toolkit, title: "test")

        // One split widget; the List is the sidebar (rendered as a `.sidebarList`), the Text is the detail.
        #expect(toolkit.widgets.filter { $0.kind == .splitView }.count == 1)
        let list = try #require(toolkit.widgets.first { $0.kind == .sidebarList })
        #expect(list.listSpec?.count == 50)
        #expect(toolkit.widgets.contains { $0.text == "None" })

        // Selecting in the sidebar updates state shown in the detail pane.
        list.listSpec?.onSelect(7)
        toolkit.drainMainThread()
        #expect(toolkit.widgets.contains { $0.text == "Selected 7" })
    }
}

// MARK: - Coalesced flush (one re-render per event, even with several @State writes)

@MainActor private struct MultiSet: View {
    @State var a = 0
    @State var b = 0
    @State var c = 0
    var body: some View {
        VStack {
            Text("sum:\(a + b + c)")
            Button("bump") { a += 1; b += 1; c += 1 }
        }
    }
}

@MainActor @Suite struct FlushCoalescingTests {
    @Test func testMultipleStateWritesInOneEventCoalesceToOneFlush() throws {
        let toolkit = MockToolkit()
        runHopApp(MultiSet(), toolkit: toolkit, title: "test")

        let before = GraphContext.flushCount
        toolkit.clearOps()
        try #require(toolkit.widgets.first { $0.title == "bump" }).action?()
        toolkit.drainMainThread()

        // Three @State writes in one action produce exactly ONE coalesced flush.
        #expect(GraphContext.flushCount == before + 1)
        #expect(toolkit.widgets.contains { $0.text == "sum:3" })
        #expect(toolkit.makeCount == 0)  // reused widgets, no rebuild
    }
}

// MARK: - ProgressView

@MainActor private struct ProgressDemo: View {
    @State var fraction = 0.3
    var body: some View {
        VStack {
            ProgressView(value: fraction)
            ProgressView()  // indeterminate
            Button("advance") { fraction = 0.8 }
        }
    }
}

@MainActor @Suite struct ProgressTests {
    @Test func testDeterminateAndIndeterminateProgress() throws {
        let toolkit = MockToolkit()
        runHopApp(ProgressDemo(), toolkit: toolkit, title: "test")

        let bars = toolkit.widgets.filter { $0.kind == .progress }
        #expect(bars.count == 2)
        #expect(bars.contains { $0.progressValue == 0.3 })                 // determinate
        #expect(bars.contains { $0.hasProgress && $0.progressValue == nil }) // indeterminate

        // Advancing the bound state updates the determinate bar in place.
        toolkit.clearOps()
        try #require(toolkit.widgets.first { $0.title == "advance" }).action?()
        toolkit.drainMainThread()
        #expect(toolkit.widgets.contains { $0.kind == .progress && $0.progressValue == 0.8 })
        #expect(toolkit.makeCount == 0)
    }
}
