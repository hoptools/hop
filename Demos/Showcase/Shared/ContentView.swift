// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The SAME ContentView builds against either HopUI or Apple's SwiftUI — no shims. Each executable
// target defines exactly one HOPUI_TOOLKIT_* constant (see Package.swift); the SwiftUI one imports
// SwiftUI, the others import HopUI, whose API mirrors SwiftUI's.
#if HOPUI_TOOLKIT_SWIFTUI
import SwiftUI
import AppKit  // NSImage, to load the bundled demo image (SwiftUI has no plain-file Image init)
import UniformTypeIdentifiers  // UTType + FileDocument for the native build's .fileExporter
#else
import HopUI
import HopUIComboBox   // a third-party HopUI component package (Components/HopUIComboBox)
#endif
import Observation  // @Observable — the same macro is used whether building against HopUI or SwiftUI
import Foundation   // sin/cos for the star's points (same on either toolkit)

/// Load the bundled demo image. HopUI has a direct file initializer; SwiftUI loads a plain bundled PNG
/// via `NSImage` (its `Image(_:bundle:)` needs an asset catalog). Mirrors the `hopTask` shim pattern.
func demoImage(_ name: String) -> Image {
    #if HOPUI_TOOLKIT_SWIFTUI
    if let url = Bundle.module.url(forResource: name, withExtension: "png"), let nsImage = NSImage(contentsOf: url) {
        return Image(nsImage: nsImage)
    }
    return Image(systemName: "photo")
    #else
    if let url = Bundle.module.url(forResource: name, withExtension: "png") {
        return Image(contentsOf: url)
    }
    return Image(systemName: "photo")
    #endif
}

/// The toolkit this build is running against, derived from the per-toolkit compile constant. This is
/// the mechanism for interposing toolkit-specific code in a shared app codebase. Module-internal (not
/// file-private) so the shared HopDemoApp / AboutView can read it too.
let hopuiToolkitName: String = {
    #if HOPUI_TOOLKIT_GTK4
    return "GTK4"
    #elseif HOPUI_TOOLKIT_QT
    return "Qt"
    #elseif HOPUI_TOOLKIT_APPKIT
    return "AppKit"
    #elseif HOPUI_TOOLKIT_WINUI
    return "WinUI"
    #elseif HOPUI_TOOLKIT_SWIFTUI
    return "SwiftUI"
    #else
    return "HopUI"
    #endif
}()

/// A shared `@Observable` model, created by the app and injected via `.environment`. Holds the
/// Observable-playground counter and the app-wide light/dark appearance (toggled from the toolbar and
/// the Appearance menu).
// nonisolated + @unchecked Sendable: the model is only ever touched on the main run loop (UI reads +
// the run-loop executor's async writes), so its properties are safe to read/mutate from the nonisolated
// `@Sendable` closures `hopTask` takes, without main-actor isolation.
@Observable
nonisolated final class DemoModel: @unchecked Sendable {
    var total = 0
    var colorScheme: ColorScheme = .light
    // Progress playground: fractions (0...1) driven by async tasks.
    var downloadProgress = 0.0
    var installProgress = 0.0
    // Tabs playground: the active tab, bound into the TabView via its `.tag(_:)` identifiers.
    var selectedTab: DemoTab = .browse

    func toggleColorScheme() {
        colorScheme = colorScheme == .dark ? .light : .dark
    }
}

/// Identifiers for the ``TabsPlayground`` tabs, used as each tab's `.tag(_:)` and stored in
/// ``DemoModel/selectedTab`` so selection is shared, observable state.
enum DemoTab: String, Hashable, CaseIterable {
    case home, browse, settings
}

/// The playgrounds shown in the sidebar selector, modeled on skipapp-showcase. Each demonstrates one
/// of the components HopUI implements so far. They are grouped into desktop UI categories by
/// ``sidebarSections`` and presented as a native sectioned list with group headers (``SidebarView``).
enum Playground: String, CaseIterable, Hashable {
    case slider, button, toggle, stepper, picker, comboBox, datePicker, colorPicker, textField, secureField, progress
    case text, accessibility, label, link
    case shapes, images, color, gradient
    case layout, disclosure, groupBox, form, tabs
    case observable, environment, menus, files
    case gesture, modifiers

    var title: String {
        switch self {
        case .slider: return "Slider"
        case .button: return "Buttons"
        case .toggle: return "Toggle"
        case .stepper: return "Stepper"
        case .picker: return "Picker"
        case .datePicker: return "Date Picker"
        case .colorPicker: return "Color Picker"
        case .textField: return "Text Field"
        case .secureField: return "Secure Field"
        case .progress: return "Progress"
        case .comboBox: return "ComboBox"
        case .text: return "Text Styles"
        case .accessibility: return "Accessibility"
        case .label: return "Label"
        case .link: return "Link"
        case .shapes: return "Shapes"
        case .images: return "Images"
        case .color: return "Color"
        case .gradient: return "Gradient"
        case .layout: return "Layout"
        case .disclosure: return "Disclosure"
        case .groupBox: return "GroupBox"
        case .form: return "Form"
        case .tabs: return "Tabs"
        case .observable: return "Observable"
        case .environment: return "Environment"
        case .menus: return "Menus"
        case .files: return "Files"
        case .gesture: return "Gestures"
        case .modifiers: return "Modifiers"
        }
    }

    /// The playground a demo starts on: the one named by the `HOP_PLAYGROUND_ID` environment variable (its
    /// raw value, e.g. `textField`), or `nil` (no selection) when unset/unrecognized. Lets
    /// `HOP_PLAYGROUND_ID=textField ./run_demo.sh all` open every toolkit on the same playground (the env
    /// is inherited by each binary).
    static var defaultSelection: Playground? {
        let id = ProcessInfo.processInfo.environment["HOP_PLAYGROUND_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return id.flatMap(Playground.init(rawValue:))
    }
}

/// One sidebar group: a section header and the playgrounds it contains. Rendered by ``SidebarView`` as a
/// `Section` of a selection-bound `List`, which becomes a native sectioned list on every toolkit.
struct SidebarSection: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [Playground]
}

/// The sidebar's categories → playgrounds, organized into logical desktop UI groups.
let sidebarSections: [SidebarSection] = [
    SidebarSection(id: "controls", title: "Controls",
                   items: [.slider, .button, .toggle, .stepper, .picker, .comboBox, .datePicker, .colorPicker,
                           .textField, .secureField, .progress, .gesture]),
    SidebarSection(id: "text", title: "Text & Accessibility",
                   items: [.text, .accessibility, .label, .link]),
    SidebarSection(id: "graphics", title: "Graphics",
                   items: [.shapes, .images, .color, .gradient]),
    SidebarSection(id: "containers", title: "Containers",
                   items: [.layout, .modifiers, .disclosure, .groupBox, .form, .tabs]),
    SidebarSection(id: "data", title: "Data & Menus",
                   items: [.observable, .environment, .menus, .files]),
]

// `hopTask` runs async work on the toolkit's run loop. The HopUI build gets it from `import HopUI`;
// the native-SwiftUI build defines an equivalent that runs on the main actor.
#if HOPUI_TOOLKIT_SWIFTUI
@MainActor func hopTask(_ body: @escaping @Sendable () async -> Void) { Task { @MainActor in await body() } }
#endif

/// Choices for the Menus playground's pickers.
enum Flavor: String, CaseIterable, Hashable {
    case vanilla, chocolate, strawberry, mint
    var label: String { rawValue.capitalized }
}

/// The Demo's sidebar: a native sectioned list — one `Section` (idiomatic group header) per category and a
/// selectable row per playground, with native single selection driving the detail. The one source compiles
/// against both HopUI and Apple's SwiftUI (HopUI renders it via the native source-list / outline widget).
private struct SidebarView: View {
    @Binding var selection: Playground?
    @Binding var navPath: [String]

    var body: some View {
        // Wrap the selection so picking a row also pops any pushed detail. Using a binding (rather than
        // `.onChange`) keeps the one source compiling identically on HopUI and SwiftUI.
        let bound = Binding<Playground?>(get: { selection }, set: { selection = $0; navPath = [] })
        List(selection: bound) {
            ForEach(sidebarSections) { section in
                Section(section.title) {
                    ForEach(section.items, id: \.self) { playground in
                        Text(playground.title).tag(playground)
                    }
                }
            }
        }
        .frame(minWidth: 240)
    }
}

/// A showcase shared by every toolkit (AppKit, GTK4, Qt, native SwiftUI). The sidebar `List` is a
/// playground selector; selecting a playground navigates the detail to it inside a `NavigationStack`
/// (which provides the title bar and supports pushing further — e.g. the Buttons playground pushes a
/// detail page via `NavigationLink`). The same source compiles against HopUI and Apple's SwiftUI.
public struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    // The shared model is created and injected by HopDemoApp; it carries the app-wide color scheme.
    @Environment(DemoModel.self) private var model
    @State private var selection: Playground? = Playground.defaultSelection
    @State private var navPath: [String] = []

    // Only state genuinely SHARED across playgrounds lives here; everything else is local @State in the
    // playground that owns it (HopUI persists @State by view identity, like SwiftUI). The Form mirrors the
    // same name / password / Wi-Fi / volume the individual control playgrounds edit, so those four are shared.
    @State private var name = ""
    @State private var password = ""
    @State private var wifiOn = true
    @State private var sliderValue = 50.0

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, navPath: $navPath)
        } detail: {
            NavigationStack(path: $navPath) {
                detail
                    .navigationTitle(selection?.title ?? "Playgrounds")
                    .navigationDestination(for: String.self) { _ in ButtonInfoView() }
            }
        }
        // Drive the window's appearance, and expose the value to descendants via @Environment(\.colorScheme).
        .preferredColorScheme(model.colorScheme)
        .environment(\.colorScheme, model.colorScheme)
        .toolbar {
            Button(model.colorScheme == .dark ? "☀ Light" : "☾ Dark") { model.toggleColorScheme() }
            Button("About") { openWindow(id: "about") }
            Text(hopuiToolkitName)
        }
    }

    @ViewBuilder private var detail: some View {
        if let selection {
            if selection == .slider {
                SliderPlayground(value: $sliderValue)
            } else if selection == .button {
                ButtonPlayground()
            } else if selection == .toggle {
                TogglePlayground(wifi: $wifiOn)   // Wi-Fi is shared with the Form; Notifications is local
            } else if selection == .stepper {
                StepperPlayground()
            } else if selection == .picker {
                PickerPlayground()
            } else if selection == .datePicker {
                DatePickerPlayground()
            } else if selection == .colorPicker {
                ColorPickerPlayground()
            } else if selection == .textField {
                TextFieldPlayground(text: $name)
            } else if selection == .secureField {
                SecureFieldPlayground(password: $password)
            } else if selection == .label {
                LabelPlayground()
            } else if selection == .link {
                LinkPlayground()
            } else if selection == .text {
                TextPlayground()
            } else if selection == .observable {
                ObservablePlayground()
            } else if selection == .environment {
                EnvironmentPlayground()
            } else if selection == .accessibility {
                AccessibilityPlayground()
            } else if selection == .shapes {
                ShapesPlayground()
            } else if selection == .images {
                ImagePlayground()
            } else if selection == .color {
                ColorPlayground()
            } else if selection == .gradient {
                GradientPlayground()
            } else if selection == .menus {
                MenuPlayground()
            } else if selection == .comboBox {
                ComboBoxPlayground()
            } else if selection == .progress {
                ProgressPlayground()
            } else if selection == .disclosure {
                DisclosurePlayground()
            } else if selection == .groupBox {
                GroupBoxPlayground()
            } else if selection == .form {
                FormPlayground(name: $name, password: $password, wifi: $wifiOn, volume: $sliderValue)
            } else if selection == .tabs {
                TabsPlayground()
            } else if selection == .files {
                FilePlayground()
            } else if selection == .gesture {
                GesturePlayground()
            } else if selection == .modifiers {
                ModifiersPlayground()
            } else {
                LayoutPlayground()
            }
        } else {
            Text("Select a playground from the sidebar")
        }
    }
}

// MARK: - Playgrounds

/// Demonstrates `.disabled(_:)` — dims and blocks input for a control or a whole subtree (the toggle
/// disables the group below it) — and `.opacity(_:)`, which composites transparency over a view and its
/// children. The same source compiles against HopUI and Apple's SwiftUI.
struct ModifiersPlayground: View {
    @State private var controlsDisabled = false
    @State private var name = "Ada"
    @State private var notifications = true
    @State private var level = 0.5

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text(".disabled — flip the switch to dim and block the controls below").font(.headline)
                Toggle("Disable the controls", isOn: $controlsDisabled)
                VStack(spacing: 12) {
                    Button("Save") { }
                    TextField("Name", text: $name)
                    Toggle("Notifications", isOn: $notifications)
                    Slider(value: $level, in: 0 ... 1)
                }
                .frame(width: 300)
                .padding(16)
                .disabled(controlsDisabled)
            }

            VStack(spacing: 12) {
                Text(".opacity — a view and its subtree composited at 100% / 60% / 30%").font(.headline)
                HStack(spacing: 16) {
                    ForEach([1.0, 0.6, 0.3], id: \.self) { fraction in
                        Text("\(Int(fraction * 100))%")
                            .frame(width: 84, height: 56)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .opacity(fraction)
                    }
                }
            }
        }
        .padding(24)
    }
}

// A tiny FileDocument for the native-SwiftUI build's `.fileExporter` (SwiftUI requires a FileDocument;
// HopUI's exporter takes the bytes directly). Only compiled in the SwiftUI build.
#if HOPUI_TOOLKIT_SWIFTUI
struct TextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
#endif

// Builds against HopUI AND Apple's SwiftUI. Uses ordinary local @State (now that HopUI persists @State by
// view identity, like SwiftUI — no need to lift it to the root). The importer is identical on both; only
// `.fileExporter` differs (SwiftUI needs a FileDocument, HopUI takes Data), so that one modifier is `#if`-selected.
struct FilePlayground: View {
    @State private var importing = false
    @State private var exporting = false
    @State private var text = "Hello from HopUI!\nEdit this, then export it."
    @State private var status = "No file chosen yet."

    var body: some View {
        #if HOPUI_TOOLKIT_SWIFTUI
        return importerView.fileExporter(isPresented: $exporting, document: TextFileDocument(text: text),
                                         contentType: .plainText, defaultFilename: "hopui.txt") { result in
            switch result {
            case .success(let url): status = "Exported to \(url.lastPathComponent)"
            case .failure(let error): status = "Export failed: \(error.localizedDescription)"
            }
        }
        #else
        return importerView.fileExporter(isPresented: $exporting, document: Data(text.utf8),
                                         contentType: .plainText, defaultFilename: "hopui.txt") { result in
            switch result {
            case .success(let url): status = "Exported to \(url.lastPathComponent)"
            case .failure(let error): status = "Export failed: \(error.localizedDescription)"
            }
        }
        #endif
    }

    private var importerView: some View {
        content.fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json],
                             allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if let loaded = try? String(contentsOf: url, encoding: .utf8) {
                    text = loaded
                    status = "Imported \(url.lastPathComponent) — \(loaded.count) characters"
                } else {
                    status = "Imported \(url.lastPathComponent)"
                }
            case .failure(let error):
                status = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            Text("Import a .txt / .json file into the field, or export the field's text")
            TextField("Contents", text: $text)
                .frame(width: 320)
            HStack(spacing: 12) {
                Button("Import…") { importing = true }
                Button("Export…") { exporting = true }
            }
            Text(status)
        }
    }
}

struct SliderPlayground: View {
    @Binding var value: Double
    var body: some View {
        VStack(spacing: 16) {
            Text("Drag the slider, or jump to a preset")
            Text("Value: \(Int(value))")
            Slider(value: $value, in: 0 ... 100)
            HStack(spacing: 12) {
                Button("0") { value = 0 }
                Button("50") { value = 50 }
                Button("100") { value = 100 }
            }
        }
    }
}

struct ButtonPlayground: View {
    @State private var count = 0
    var body: some View {
        VStack(spacing: 16) {
            Text("Tap the buttons to change the count")
            Text("Count: \(count)")
            HStack(spacing: 12) {
                Button("–") { count -= 1 }
                Button("Reset") { count = 0 }
                Button("+") { count += 1 }
            }
            // Real push navigation: appends "button-info" to the stack's path; the detail's
            // navigationDestination(for: String.self) builds the destination, with a back button.
            NavigationLink("About buttons ›", value: "button-info")
        }
    }
}

struct TogglePlayground: View {
    @Binding var wifi: Bool                       // shared with the Form
    @State private var notifications = false       // local to this playground
    var body: some View {
        VStack(spacing: 16) {
            Text("Boolean on/off controls bound to @State")
            VStack(spacing: 10) {
                Toggle("Wi-Fi", isOn: $wifi)
                Toggle("Notifications", isOn: $notifications)
            }
            .frame(width: 260)
            Text("Wi-Fi is \(wifi ? "on" : "off") · Notifications \(notifications ? "on" : "off")")
        }
    }
}

struct StepperPlayground: View {
    @State private var quantity = 3
    var body: some View {
        VStack(spacing: 16) {
            Text("Increment or decrement a bound value (0…10)")
            Stepper("Quantity: \(quantity)", value: $quantity, in: 0 ... 10)
                .frame(width: 260)
            Text("You picked \(quantity)")
        }
    }
}

/// Demonstrates `Picker` across all four styles (`.menu`, `.segmented`, `.radioGroup`, `.automatic`),
/// different selection value types (enum + Int), `ForEach`-built and statically-tagged options, and a live
/// readout of every binding. The same source compiles against HopUI and Apple's SwiftUI.
struct PickerPlayground: View {
    enum Fruit: String, CaseIterable, Identifiable, Hashable {
        case apple, banana, cherry, dragonfruit
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    enum Alignment: String, CaseIterable, Identifiable, Hashable {
        case leading, center, trailing
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @State private var menuFruit: Fruit = .banana
    @State private var segment: Alignment = .center
    @State private var radioFruit: Fruit = .cherry
    @State private var size: Int = 1

    private let sizes = ["Small", "Medium", "Large", "Huge"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Menu: \(menuFruit.label)  ·  Segmented: \(segment.label)  ·  Radio: \(radioFruit.label)  ·  Size: \(sizes[size])")
                    .fontWeight(.semibold)

                GroupBox("Menu (drop-down)") {
                    Picker("Fruit", selection: $menuFruit) {
                        ForEach(Fruit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }

                GroupBox("Segmented") {
                    Picker("Alignment", selection: $segment) {
                        ForEach(Alignment.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                GroupBox("Radio group") {
                    Picker("Fruit", selection: $radioFruit) {
                        ForEach(Fruit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                }

                GroupBox("Automatic (statically-tagged Int options)") {
                    Picker("Size", selection: $size) {
                        Text("Small").tag(0)
                        Text("Medium").tag(1)
                        Text("Large").tag(2)
                        Text("Huge").tag(3)
                    }
                    .pickerStyle(.automatic)
                }

                Text("Pick options in any control above and watch the readout — each style is a different "
                     + "native widget per toolkit (pop-up / segmented control / radio buttons).")
                    .foregroundStyle(.gray)
            }
            .padding(24)
        }
    }
}

struct DatePickerPlayground: View {
    @State private var date = Date()
    var body: some View {
        // Scrolls because the graphical/calendar variations are tall on some toolkits (GTK4 renders
        // every date picker as an inline calendar). Every variation binds to the same @State Date.
        ScrollView {
            VStack(spacing: 18) {
                Text("Each variation binds to the same @State Date")
                DatePicker("Appointment", selection: $date)
                DatePicker("Date only", selection: $date, displayedComponents: .date)
                DatePicker("Time only", selection: $date, displayedComponents: .hourAndMinute)
                DatePicker("Calendar", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                Text("Selected: \(date)")
            }
        }
    }
}

struct ColorPickerPlayground: View {
    @State private var color = Color.blue
    var body: some View {
        VStack(spacing: 18) {
            Text("Pick a color — bound to @State and previewed below")
            ColorPicker("Tint (with opacity)", selection: $color)
            ColorPicker("Solid (no opacity)", selection: $color, supportsOpacity: false)
            RoundedRectangle(cornerRadius: 12)
                .fill(color)
                .frame(width: 220, height: 80)
        }
    }
}

struct TextFieldPlayground: View {
    @Binding var text: String
    var body: some View {
        VStack(spacing: 16) {
            Text("Type your name")
            TextField("Name", text: $text)
            Text(text.isEmpty ? "Hello there!" : "Hello, \(text)!")
        }
    }
}

struct SecureFieldPlayground: View {
    @Binding var password: String
    var body: some View {
        VStack(spacing: 16) {
            Text("Masked text entry — characters are hidden")
            SecureField("Password", text: $password)
                .frame(width: 260)
            Text(password.isEmpty ? "Type a password" : "Length: \(password.count) characters")
        }
    }
}

struct LabelPlayground: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A title paired with a leading icon (Label)")
            Label("Documents", systemImage: "folder.fill")
            Label("Favorites", systemImage: "star.fill")
            Label("Downloads", systemImage: "arrow.down.circle.fill")
            Label("Trash", systemImage: "trash.fill")
        }
    }
}

struct LinkPlayground: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Links open in your default browser")
            Link("Hop — hoppy", destination: URL(string: "https://github.com/hoptools/hop")!)
            Link("Docs — hoppy", destination: URL(string: "https://github.com/hoptools/hop")!)
        }
    }
}

struct ObservablePlayground: View {
    // The model arrives entirely through the environment — no parameters, no reference to ContentView.
    @Environment(DemoModel.self) private var model
    // The current appearance, read from the environment (set by ContentView's .environment(\.colorScheme,…)).
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 16) {
            Text("Shared @Observable state, read & written via @Environment")
            Text("Total: \(model.total)")
            HStack(spacing: 12) {
                Button("−1") { model.total -= 1 }
                Button("+1") { model.total += 1 }
            }
            Text("Current appearance (via @Environment(\\.colorScheme)): \(colorScheme == .dark ? "dark" : "light")")
        }
    }
}

// MARK: - Custom @Environment values (declared exactly like SwiftUI)

/// A custom environment value: an `EnvironmentKey` with a default, plus an `EnvironmentValues` computed
/// property that reads/writes `self[Key.self]`. This is the standard SwiftUI recipe and compiles
/// unchanged against both HopUI and Apple's SwiftUI.
private struct GreetingKey: EnvironmentKey {
    static let defaultValue = "Hello, World"
}

/// A struct environment value, to show custom values aren't limited to primitives.
struct AppTheme: Equatable {
    var name: String
    var accent: Color
}
private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme(name: "Default", accent: .blue)
}

extension EnvironmentValues {
    var greeting: String {
        get { self[GreetingKey.self] }
        set { self[GreetingKey.self] = newValue }
    }
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Reads the custom `\.greeting` value — exactly like reading a built-in like `\.colorScheme`.
private struct GreetingReader: View {
    @Environment(\.greeting) private var greeting
    var body: some View { Text("greeting = \"\(greeting)\"") }
}

/// Reads the custom struct `\.appTheme` value and uses it.
private struct ThemeReader: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6).fill(theme.accent).frame(width: 28, height: 20)
            Text("appTheme = \(theme.name)")
        }
    }
}

/// Demonstrates declaring and using *custom* `@Environment` values — default, injection, nested override,
/// reactivity, and a struct value — all with the same API as SwiftUI's built-ins.
struct EnvironmentPlayground: View {
    @State private var greeting = "Bonjour"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Custom @Environment values").font(.title3).fontWeight(.semibold)
            Text("Declared with EnvironmentKey + an EnvironmentValues extension — exactly like SwiftUI. Inject with .environment(\\.key, value); read with @Environment(\\.key).")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("No injection → the key's default value:")
                GreetingReader()
                Text("Injected, and reactive to this picker:")
                GreetingReader().environment(\.greeting, greeting)
                Picker("Greeting", selection: $greeting) {
                    Text("Bonjour").tag("Bonjour")
                    Text("Hej").tag("Hej")
                    Text("Hola").tag("Hola")
                    Text("こんにちは").tag("こんにちは")
                }
            }

            Divider()

            Text("Nesting — the nearest injection wins:").fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 6) {
                GreetingReader()                                       // inherits the outer injection
                GreetingReader().environment(\.greeting, "inner override")  // overrides it
            }
            .environment(\.greeting, "outer value")

            Divider()

            Text("A struct environment value:").fontWeight(.semibold)
            ThemeReader()                                                            // default theme
            ThemeReader().environment(\.appTheme, AppTheme(name: "Sunset", accent: .orange))
        }
        .padding(20)
    }
}

struct TextPlayground: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("Default text")
            Text("Large & bold").font(.system(size: 28, weight: .bold))
            Text("Semantic title font").font(.title)
            Text("Just a heavier weight").fontWeight(.semibold)
            Text("Custom family (Courier, 18)").font(.custom("Courier", size: 18))
            Text("Foreground style: red").foregroundStyle(.red)
            Text("Blue, medium, size 18").font(.system(size: 18, weight: .medium)).foregroundStyle(.blue)
            Text("Text on a yellow background").background(.yellow)
            // Font and foreground style are inherited: both lines below pick them up from the VStack.
            VStack(spacing: 6) {
                Text("Inherited style — line one")
                Text("Inherited style — line two")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.green)
        }
    }
}

struct AccessibilityPlayground: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Accessibility")
                .accessibilityAddTraits(.isHeader)

            // The visible glyphs are meaningless to a screen reader, so we give a label + value:
            // VoiceOver reads "Rating, 4 out of 5 stars" instead of "star star star…".
            Text("★★★★☆")
                .accessibilityLabel("Rating")
                .accessibilityValue("4 out of 5 stars")

            Button("Save") { }
                .accessibilityLabel("Save document")
                .accessibilityHint("Writes your changes to disk")

            // Purely decorative — hidden from assistive technologies entirely.
            Text("— decorative divider —")
                .accessibilityHidden(true)

            // A stable identifier for UI testing (queryable in the accessibility tree).
            Text("Build 2026.6")
                .accessibilityIdentifier("build-number")
        }
    }
}

struct ShapesPlayground: View {
    var body: some View {
        VStack(spacing: 18) {
            Text("Built-in shapes, filled")
            HStack(spacing: 14) {
                Rectangle().fill(.red).frame(width: 54, height: 40)
                RoundedRectangle(cornerRadius: 12).fill(.orange).frame(width: 54, height: 40)
                Circle().fill(.blue).frame(width: 44, height: 44)
                Capsule().fill(.green).frame(width: 64, height: 34)
                Ellipse().fill(.purple).frame(width: 64, height: 40)
            }

            Text("Stroked outlines & open paths")
            HStack(spacing: 14) {
                Rectangle().stroke(.red, lineWidth: 3).frame(width: 54, height: 40)
                RoundedRectangle(cornerRadius: 12).stroke(.orange, lineWidth: 3).frame(width: 54, height: 40)
                Circle().stroke(.blue, lineWidth: 3).frame(width: 44, height: 44)
                Target().stroke(.pink, lineWidth: 2).frame(width: 48, height: 48)
                Wave().stroke(.teal, lineWidth: 3).frame(width: 84, height: 40)
            }

            Text("Transforms: rotate, scale, offset")
            HStack(spacing: 24) {
                Rectangle().fill(.indigo).frame(width: 40, height: 40).rotationEffect(.degrees(45))
                Triangle().fill(.mint).frame(width: 40, height: 40).scaleEffect(1.3)
                Star().fill(.yellow).frame(width: 44, height: 44).rotationEffect(.degrees(18))
                Arrow().fill(.cyan).frame(width: 50, height: 36).offset(x: 8, y: 0)
            }

            Text("Custom Path shapes & combinations")
            HStack(spacing: 18) {
                Star(points: 5, innerRatio: 0.42).fill(.yellow).frame(width: 50, height: 50)
                Heart().fill(.red).frame(width: 50, height: 46)
                Arrow().fill(.blue).frame(width: 56, height: 40)
                House().fill(.brown).frame(width: 50, height: 50)
                Triangle().stroke(.green, lineWidth: 3).frame(width: 48, height: 48)
            }
        }
    }
}

/// A labeled gradient sample: the gradient (or gradient-filled shape) above a caption.
private struct GradCell<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder _ content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(spacing: 4) {
            content
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Demonstrates `LinearGradient`, `RadialGradient`, and `AngularGradient` across a wide range of
/// configurations — as standalone views, as `Shape` fills, with custom stops, partial sweeps, transforms,
/// and alpha fades. Linear & radial are native on every toolkit; angular is native on Qt, hand-rendered on
/// AppKit/GTK, and approximated (radial) on WinUI, which has no conic brush.
struct GradientPlayground: View {
    private let rainbow: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]
    private let cellW: CGFloat = 100
    private let cellH: CGFloat = 60

    var body: some View {
        VStack(spacing: 14) {
            Text("LinearGradient — direction via start/end UnitPoints, even & custom stops")
            HStack(spacing: 12) {
                GradCell("top→bottom") {
                    LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
                        .frame(width: cellW, height: cellH)
                }
                GradCell("leading→trailing") {
                    LinearGradient(colors: [.red, .yellow], startPoint: .leading, endPoint: .trailing)
                        .frame(width: cellW, height: cellH)
                }
                GradCell("diagonal") {
                    LinearGradient(colors: [.green, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: cellW, height: cellH)
                }
                GradCell("rainbow") {
                    LinearGradient(gradient: Gradient(colors: rainbow), startPoint: .leading, endPoint: .trailing)
                        .frame(width: cellW, height: cellH)
                }
                GradCell("hard stops") {
                    LinearGradient(stops: [
                        .init(color: .red, location: 0), .init(color: .red, location: 0.5),
                        .init(color: .blue, location: 0.5), .init(color: .blue, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                        .frame(width: cellW, height: cellH)
                }
            }

            Text("RadialGradient — center, off-center, ring (startRadius>0), multi-stop")
            HStack(spacing: 12) {
                GradCell("center") {
                    RadialGradient(colors: [.yellow, .red], center: .center, startRadius: 0, endRadius: 55)
                        .frame(width: cellW, height: cellH)
                }
                GradCell("off-center") {
                    RadialGradient(colors: [.white, .blue], center: .topLeading, startRadius: 0, endRadius: 90)
                        .frame(width: cellW, height: cellH)
                }
                GradCell("ring") {
                    RadialGradient(colors: [.clear, .orange, .clear], center: .center, startRadius: 8, endRadius: 50)
                        .frame(width: cellW, height: cellH)
                }
                GradCell("multi-stop") {
                    RadialGradient(gradient: Gradient(colors: [.white, .cyan, .blue, .indigo]),
                                   center: .center, startRadius: 0, endRadius: 55)
                        .frame(width: cellW, height: cellH)
                }
            }

            Text("AngularGradient — full sweep, partial arc, rotated start angle")
            HStack(spacing: 12) {
                GradCell("full sweep") {
                    AngularGradient(colors: rainbow + [.red], center: .center)
                        .frame(width: cellH, height: cellH)
                }
                GradCell("0°→180°") {
                    AngularGradient(colors: [.yellow, .red], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(180))
                        .frame(width: cellH, height: cellH)
                }
                GradCell("start 90°") {
                    AngularGradient(gradient: Gradient(colors: rainbow + [.red]), center: .center, angle: .degrees(90))
                        .frame(width: cellH, height: cellH)
                }
                GradCell("two-tone") {
                    AngularGradient(colors: [.mint, .indigo, .mint], center: .center)
                        .frame(width: cellH, height: cellH)
                }
            }

            Text("As Shape fills — Circle, RoundedRectangle, Capsule, Ellipse")
            HStack(spacing: 16) {
                GradCell("linear") {
                    Circle().fill(LinearGradient(colors: [.pink, .orange], startPoint: .top, endPoint: .bottom))
                        .frame(width: cellH, height: cellH)
                }
                GradCell("radial") {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(RadialGradient(colors: [.white, .blue], center: .center, startRadius: 0, endRadius: 45))
                        .frame(width: 84, height: cellH)
                }
                GradCell("angular") {
                    Capsule().fill(AngularGradient(colors: rainbow + [.red], center: .center))
                        .frame(width: 92, height: cellH)
                }
                GradCell("linear") {
                    Ellipse().fill(LinearGradient(colors: [.teal, .indigo], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 92, height: cellH)
                }
            }

            Text("Advanced — rotated view, alpha fade, opacity stops over a backdrop")
            HStack(spacing: 16) {
                GradCell("rotated 20°") {
                    LinearGradient(colors: [.purple, .cyan], startPoint: .leading, endPoint: .trailing)
                        .frame(width: cellW, height: cellH)
                        .rotationEffect(.degrees(20))
                }
                GradCell("alpha fade") {
                    LinearGradient(colors: [.blue, Color(red: 0, green: 0, blue: 1, opacity: 0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: cellW, height: cellH)
                }
                GradCell("scaled 1.2×") {
                    RadialGradient(colors: [.yellow, .red, .purple], center: .center, startRadius: 0, endRadius: 40)
                        .frame(width: cellH, height: cellH)
                        .scaleEffect(1.2)
                }
            }
        }
    }
}

struct ImagePlayground: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("SF Symbols — tinted (native on Apple; icon-theme fallback on GTK/Qt)")
            HStack(spacing: 20) {
                Image(systemName: "star.fill").resizable().scaledToFit().frame(width: 36, height: 36)
                    .foregroundStyle(.yellow)
                Image(systemName: "heart.fill").resizable().scaledToFit().frame(width: 36, height: 36)
                    .foregroundStyle(.red)
                Image(systemName: "bolt.fill").resizable().scaledToFit().frame(width: 36, height: 36)
                    .foregroundStyle(.blue)
            }

            Text("Bundled image — renders identically on every toolkit")
            demoImage("hop-logo").resizable().scaledToFit().frame(width: 96, height: 96)

            Text("Content modes in a 130×72 frame: scaledToFit · stretch")
            HStack(spacing: 16) {
                demoImage("hop-logo").resizable().scaledToFit().frame(width: 130, height: 72).background(.yellow)
                demoImage("hop-logo").resizable().frame(width: 130, height: 72)
            }
        }
    }
}

/// A single named-color sample: a filled swatch with its name beneath.
private struct ColorSwatch: View {
    let name: String
    let color: Color
    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8).fill(color).frame(width: 64, height: 40)
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One entry in a color swatch grid.
private struct DemoColor: Identifiable {
    let name: String
    let color: Color
    var id: String { name }
    init(_ name: String, _ color: Color) { self.name = name; self.color = color }
}

/// Demonstrates `Color`: SwiftUI's adaptive *content colors* (`.primary`/`.secondary`/`.tertiary`/
/// `.quaternary`), which resolve against `@Environment(\.colorScheme)` — toggle Dark/Light in the top bar
/// to watch them flip black↔white — plus the standard named palette.
struct ColorPlayground: View {
    private let namedRows: [[DemoColor]] = [
        [DemoColor("red", .red), DemoColor("orange", .orange), DemoColor("yellow", .yellow),
         DemoColor("green", .green), DemoColor("mint", .mint)],
        [DemoColor("teal", .teal), DemoColor("cyan", .cyan), DemoColor("blue", .blue),
         DemoColor("indigo", .indigo), DemoColor("purple", .purple)],
        [DemoColor("pink", .pink), DemoColor("brown", .brown), DemoColor("gray", .gray),
         DemoColor("black", .black), DemoColor("white", .white)],
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Adaptive content colors").font(.title3).fontWeight(.semibold)
                Text("Black in light mode, white in dark, at decreasing prominence. Toggle Dark/Light in the top bar to watch them adapt.")
                    .foregroundStyle(.secondary)

                // The hierarchy as foreground (text) — each line a step fainter.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Primary — the standard label color").foregroundStyle(.primary)
                    Text("Secondary — supporting text").foregroundStyle(.secondary)
                    Text("Tertiary — even less prominent").foregroundStyle(.tertiary)
                    Text("Quaternary — the faintest").foregroundStyle(.quaternary)
                }

                // The same hierarchy as swatches (shapes filled with the adaptive color). Written inline
                // because Apple's SwiftUI exposes `.tertiary`/`.quaternary` only as `ShapeStyle` (not
                // `Color`), so they can't be stored in a `[Color]`; `.fill(_:)` accepts both, dual-compiling.
                HStack(spacing: 12) {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 8).fill(.primary).frame(width: 64, height: 40)
                        Text("primary").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 8).fill(.secondary).frame(width: 64, height: 40)
                        Text("secondary").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 8).fill(.tertiary).frame(width: 64, height: 40)
                        Text("tertiary").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 64, height: 40)
                        Text("quaternary").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("Named colors").font(.title3).fontWeight(.semibold)
                ForEach(namedRows.indices, id: \.self) { row in
                    HStack(spacing: 12) {
                        ForEach(namedRows[row]) { ColorSwatch(name: $0.name, color: $0.color) }
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Custom shapes (each implemented purely with the Path API, identical on HopUI and SwiftUI)

/// An equilateral-ish triangle pointing up, filling its rect.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// An N-pointed star (default 5), alternating outer/inner radius around the center.
struct Star: Shape {
    var points: Int = 5
    var innerRatio: CGFloat = 0.4
    func path(in rect: CGRect) -> Path {
        Path { p in
            let cx = rect.midX, cy = rect.midY
            let outer = Double(min(rect.width, rect.height)) / 2
            let inner = outer * Double(innerRatio)
            let count = points * 2
            for i in 0 ..< count {
                let angle = (Double(i) / Double(count)) * 2 * Double.pi - Double.pi / 2
                let r = (i % 2 == 0) ? outer : inner
                let pt = CGPoint(x: cx + CGFloat(r * cos(angle)), y: cy + CGFloat(r * sin(angle)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }
}

/// A heart, built from four cubic Bézier segments.
struct Heart: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
            p.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.30))
            p.addCurve(to: CGPoint(x: x, y: y + h * 0.30),
                       control1: CGPoint(x: x + w * 0.5, y: y),
                       control2: CGPoint(x: x, y: y))
            p.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h),
                       control1: CGPoint(x: x, y: y + h * 0.6),
                       control2: CGPoint(x: x + w * 0.5, y: y + h * 0.75))
            p.addCurve(to: CGPoint(x: x + w, y: y + h * 0.30),
                       control1: CGPoint(x: x + w * 0.5, y: y + h * 0.75),
                       control2: CGPoint(x: x + w, y: y + h * 0.6))
            p.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.30),
                       control1: CGPoint(x: x + w, y: y),
                       control2: CGPoint(x: x + w * 0.5, y: y))
            p.closeSubpath()
        }
    }
}

/// A right-pointing block arrow.
struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
            p.move(to: CGPoint(x: x, y: y + h * 0.35))
            p.addLine(to: CGPoint(x: x + w * 0.55, y: y + h * 0.35))
            p.addLine(to: CGPoint(x: x + w * 0.55, y: y + h * 0.15))
            p.addLine(to: CGPoint(x: x + w, y: y + h * 0.5))
            p.addLine(to: CGPoint(x: x + w * 0.55, y: y + h * 0.85))
            p.addLine(to: CGPoint(x: x + w * 0.55, y: y + h * 0.65))
            p.addLine(to: CGPoint(x: x, y: y + h * 0.65))
            p.closeSubpath()
        }
    }
}

/// A sine-like wave drawn with two quadratic curves (an open path, meant to be stroked).
struct Wave: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let x = rect.minX, w = rect.width
            let midY = rect.midY
            p.move(to: CGPoint(x: x, y: midY))
            p.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: midY),
                           control: CGPoint(x: x + w * 0.25, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: x + w, y: midY),
                           control: CGPoint(x: x + w * 0.75, y: rect.maxY))
        }
    }
}

/// Concentric rings in a single path — a combination of primitives, meant to be stroked.
struct Target: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let rings = 3
            let step = min(rect.width, rect.height) / CGFloat(rings) / 2
            for i in 0 ..< rings {
                let inset = CGFloat(i) * step
                p.addEllipse(in: rect.insetBy(dx: inset, dy: inset))
            }
        }
    }
}

/// A simple house: a triangular roof plus a rectangular body, composed in one path.
struct House: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
            p.move(to: CGPoint(x: x, y: y + h * 0.45))
            p.addLine(to: CGPoint(x: x + w * 0.5, y: y))
            p.addLine(to: CGPoint(x: x + w, y: y + h * 0.45))
            p.closeSubpath()
            p.addRect(CGRect(x: x + w * 0.15, y: y + h * 0.45, width: w * 0.7, height: h * 0.55))
        }
    }
}

struct MenuPlayground: View {
    @State private var flavor = Flavor.vanilla
    @State private var quantity = 1
    @State private var lastAction = "—"

    var body: some View {
        VStack(spacing: 18) {
            Text("Drop-down menus, pickers, and submenus")

            // An action Menu: buttons, separators (Divider), and a nested submenu.
            Menu("Actions") {
                Button("New") { lastAction = "New" }
                Button("Open") { lastAction = "Open" }
                Divider()
                Button("Save") { lastAction = "Save" }
                Menu("Export") {
                    Button("Export as PDF") { lastAction = "Export as PDF" }
                    Button("Export as PNG") { lastAction = "Export as PNG" }
                }
                Divider()
                Button("Delete") { lastAction = "Delete" }
            }
            Text("Last action: \(lastAction)")

            Divider()

            // A Picker bound to an enum @State, with the choices supplied by a ForEach + .tag.
            Picker("Flavor", selection: $flavor) {
                ForEach(Flavor.allCases, id: \.self) { flavor in
                    Text(flavor.label).tag(flavor)
                }
            }
            Text("Chosen flavor: \(flavor.label)")

            // A second Picker bound to an Int @State — two independent bindings.
            Picker("Quantity", selection: $quantity) {
                ForEach(1 ... 5, id: \.self) { n in
                    Text("\(n) scoop\(n == 1 ? "" : "s")").tag(n)
                }
            }
            Text("Your order: \(quantity) × \(flavor.label)")
        }
    }
}

/// Demonstrates `.onTapGesture`. Tapping the first box increments a counter and flips its color; the
/// second responds only to a double-tap. Each tap mutates `@State`, which re-renders the counts — the same
/// reactive path a `Button` uses, but driven by a native tap recognizer on every toolkit.
/// A labeled, fixed-size gesture target. The caller chains the gesture modifier onto it.
private struct GestureTile: View {
    let label: String
    let color: Color
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(color).frame(width: 116, height: 80)
            Text(label).font(.caption).foregroundStyle(.white)
        }
        .frame(width: 116, height: 80)
    }
}

/// Demonstrates the full gesture set: tap, double-tap, long-press, hover (the pointer gestures, on every
/// toolkit) plus drag, magnify, and rotate (the value-carrying `Gesture`s — drag everywhere; magnify/rotate
/// on AppKit & GTK via trackpad). Each tile/shape reacts live to the gesture's value.
struct GesturePlayground: View {
    @State private var taps = 0
    @State private var doubleTaps = 0
    @State private var longPresses = 0
    @State private var hovering = false
    @State private var dragLive = CGSize.zero       // translation during an active drag
    @State private var dragCommitted = CGSize.zero  // accumulated across finished drags
    @State private var scale: CGFloat = 1
    @State private var rotation = Angle.zero

    var body: some View {
        VStack(spacing: 18) {
            Text("Tap · double-tap · long-press · hover").font(.headline)
            HStack(spacing: 14) {
                GestureTile(label: "Tap: \(taps)", color: taps % 2 == 0 ? .blue : .green)
                    .onTapGesture { taps += 1 }
                GestureTile(label: "Double: \(doubleTaps)", color: doubleTaps % 2 == 0 ? .orange : .purple)
                    .onTapGesture(count: 2) { doubleTaps += 1 }
                GestureTile(label: "Hold: \(longPresses)", color: .pink)
                    .onLongPressGesture(minimumDuration: 0.5) { longPresses += 1 }
                GestureTile(label: hovering ? "Hovering!" : "Hover me", color: hovering ? .mint : .gray)
                    .onHover { hovering = $0 }
            }

            Text("Drag · magnify · rotate (drag with the mouse; pinch/rotate on a trackpad)").font(.headline)
            HStack(spacing: 40) {
                VStack(spacing: 6) {
                    Circle().fill(.blue).frame(width: 80, height: 80)
                        .offset(x: dragCommitted.width + dragLive.width, y: dragCommitted.height + dragLive.height)
                        .gesture(
                            DragGesture()
                                .onChanged { dragLive = $0.translation }
                                .onEnded { value in
                                    dragCommitted.width += value.translation.width
                                    dragCommitted.height += value.translation.height
                                    dragLive = .zero
                                }
                        )
                    Text("Drag").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 16).fill(.orange).frame(width: 80, height: 80)
                        .scaleEffect(scale)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { scale = $0.magnification }
                                .onEnded { _ in scale = 1 }
                        )
                    Text(String(format: "Magnify ×%.2f", scale)).font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    Rectangle().fill(.purple).frame(width: 80, height: 80)
                        .rotationEffect(rotation)
                        .gesture(
                            RotateGesture()
                                .onChanged { rotation = $0.rotation }
                                .onEnded { _ in rotation = .zero }
                        )
                    Text(String(format: "Rotate %.0f°", rotation.degrees)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
    }
}

/// Demonstrates `ComboBox` — a control from the *separate* HopUIComboBox package, backed by each toolkit's
/// native *editable* combo box (NSComboBox / GtkComboBoxText / QComboBox / WinUI ComboBox) through HopUI's
/// public extensibility seams. The value is a plain `String`: the user can type freeform text **or** pick
/// one of the menu items (which fills in the text). On the native-SwiftUI reference build (which has no
/// `ComboBox`) it falls back to a `TextField`, so the same source still compiles everywhere.
struct ComboBoxPlayground: View {
    @State private var fruit = "Banana"        // starts on a menu item
    @State private var size = "42 mm (custom)" // starts on freeform text, not in the menu
    @State private var flavor = ""             // starts empty → shows the placeholder
    private let fruits = ["Apple", "Banana", "Cherry", "Dragonfruit", "Elderberry"]
    private let sizes = ["Small", "Medium", "Large", "Extra Large"]
    private let flavors = ["Vanilla", "Chocolate", "Strawberry", "Pistachio"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ComboBox — a third-party HopUI control").font(.title3).fontWeight(.semibold)
            Text("Defined in the standalone HopUIComboBox package and backed by each toolkit's native editable combo box, added purely through HopUI's public extensibility seams (HopRepresentable + WidgetComponent.makeNative) — no edits to hop.")
                .foregroundStyle(.gray)
            Text("Type freeform text or pick a menu item — the binding is a plain String.")
                .foregroundStyle(.gray)

            VStack(alignment: .leading, spacing: 8) {
                Text("Fruit: \(fruit)").fontWeight(.semibold)
                comboBox(fruits, text: $fruit)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Size: \(size)").fontWeight(.semibold)
                comboBox(sizes, text: $size)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Flavor: \(flavor.isEmpty ? "—" : flavor)").fontWeight(.semibold)
                comboBox(flavors, text: $flavor, placeholder: "Pick or type a flavor…")
            }
        }
        .padding(20)
    }

    @ViewBuilder private func comboBox(_ items: [String], text: Binding<String>, placeholder: String = "") -> some View {
        #if HOPUI_TOOLKIT_SWIFTUI
        // Apple's SwiftUI has no editable ComboBox; the closest reference for a freeform String is a
        // TextField, whose title doubles as its placeholder.
        TextField(placeholder, text: text)
            .frame(width: 220)
        #else
        ComboBox(items, text: text, placeholder: placeholder).frame(width: 220)
        #endif
    }
}

struct ProgressPlayground: View {
    // The progress fractions live in the shared @Observable model; async tasks mutate them and the
    // ProgressViews re-render. (Reads here register the dependency that drives those re-renders.)
    @Environment(DemoModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Text("Determinate progress driven by async tasks (Task + await on the toolkit's run loop)")

            ProgressView(value: model.downloadProgress)
            Text("Download: \(Int(model.downloadProgress * 100))%")
            Button("Start Download") {
                let model = model  // capture the model instance on the main actor, then drive it async
                hopTask {
                    for step in 0 ... 100 {
                        try? await Task.sleep(for: .milliseconds(20))
                        model.downloadProgress = Double(step) / 100
                    }
                }
            }

            Divider()

            ProgressView(value: model.installProgress)
            Text("Install: \(Int(model.installProgress * 100))%")
            Button("Start Install (slower)") {
                let model = model
                hopTask {
                    for step in 0 ... 100 {
                        try? await Task.sleep(for: .milliseconds(45))
                        model.installProgress = Double(step) / 100
                    }
                }
            }

            Button("Reset") {
                model.downloadProgress = 0
                model.installProgress = 0
            }

            Divider()

            Text("Indeterminate")
            ProgressView()
        }
    }
}

/// Demonstrates the framework-owned layout engine: ZStack overlay, HStack/VStack alignment + Spacer,
/// padding/frame, a GeometryReader reporting its measured size, and a ScrollView wrapping a virtualizing
/// LazyVStack of 1,000 rows (only the visible window is ever materialized).
struct LayoutPlayground: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("ZStack (overlapping, aligned)").font(.system(size: 16, weight: .semibold))
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(.blue).frame(width: 200, height: 90)
                    RoundedRectangle(cornerRadius: 8).fill(.white).frame(width: 120, height: 40)
                    Text("Centered")
                }

                Text("HStack + Spacer (pushes apart)").font(.system(size: 16, weight: .semibold))
                HStack {
                    Text("Leading")
                    Spacer()
                    Text("Trailing")
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.yellow)

                Text("Padding & fixed frame").font(.system(size: 16, weight: .semibold))
                Text("Padded + centered in a 220×56 frame")
                    .padding()
                    .frame(width: 220, height: 56, alignment: .center)
                    .background(.green)

                Text("GeometryReader (reports its size)").font(.system(size: 16, weight: .semibold))
                GeometryReader { proxy in
                    Text("offered \(Int(proxy.size.width)) × \(Int(proxy.size.height))")
                        .foregroundStyle(.blue)
                }
                .frame(height: 44)

                Text("ScrollView + LazyVStack (1,000 rows, virtualized)").font(.system(size: 16, weight: .semibold))
                LazyVStack(spacing: 6) {
                    ForEach(0 ..< 1000, id: \.self) { i in
                        HStack {
                            Text("Row \(i)")
                            Spacer()
                            Text("#\(i)").foregroundStyle(.blue)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(i.isMultiple(of: 2) ? .white : .yellow)
                    }
                }
            }
            .padding()
        }
    }
}

/// Demonstrates `DisclosureGroup`: collapsible sections with a disclosure triangle, including nesting.
/// Expansion is self-managed (HopUI keeps it in a per-identity graph source; SwiftUI in internal state),
/// so the playground needs no parent state. The same source compiles against HopUI and Apple's SwiftUI.
struct DisclosurePlayground: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Collapsible sections — click a header to expand or collapse")

            DisclosureGroup("Getting Started") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HopUI mirrors SwiftUI's API surface.")
                    Text("The same ContentView builds against HopUI and SwiftUI.")
                }
            }

            DisclosureGroup("Native tree toolkits") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• AppKit — NSOutlineView")
                    Text("• GTK4 — GtkTreeListModel + GtkListView")
                    Text("• Qt — QTreeWidget")
                    DisclosureGroup("Nested details") {
                        Text("Disclosure groups can nest arbitrarily.")
                    }
                }
            }

            DisclosureGroup("Tips") {
                Text("The sidebar selector is the same OutlineGroup tree component.")
            }
        }
    }
}

struct GroupBoxPlayground: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Titled, bordered grouping boxes")
            GroupBox("Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("128 GB of 256 GB used")
                    ProgressView(value: 0.5)
                }
            }
            .frame(width: 320)
            GroupBox("About") {
                Text("HopUI renders SwiftUI natively on macOS, GTK, and Qt.")
            }
            .frame(width: 320)
        }
    }
}

struct FormPlayground: View {
    @Binding var name: String
    @Binding var password: String
    @Binding var wifi: Bool
    @Binding var volume: Double
    var body: some View {
        Form {
            Section("Account") {
                TextField("Name", text: $name)
                SecureField("Password", text: $password)
            }
            Section("Preferences") {
                Toggle("Wi-Fi", isOn: $wifi)
                Text("Volume: \(Int(volume))")
                Slider(value: $volume, in: 0 ... 100)
            }
        }
    }
}

struct TabsPlayground: View {
    @Environment(DemoModel.self) private var model

    var body: some View {
        // Bind the TabView's selection to shared @Observable state. Tags identify each tab; selecting one
        // writes its tag to `model.selectedTab`, and changing `model.selectedTab` switches tabs.
        let selectedTab = Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 })
        VStack(spacing: 12) {
            Text("Selected tab: \(model.selectedTab.rawValue) — bound to DemoModel.selectedTab")
                .foregroundStyle(.gray)
            TabView(selection: selectedTab) {
                VStack(spacing: 10) {
                    Text("Welcome to HopUI").font(.title)
                    Text("A native SwiftUI for the desktop.")
                }
                .tabItem { Text("Home") }
                .tag(DemoTab.home)

                VStack(spacing: 10) {
                    Text("Browse").font(.title)
                    Text("Switch tabs to change this pane.")
                }
                .tabItem { Text("Browse") }
                .tag(DemoTab.browse)

                VStack(spacing: 10) {
                    Text("Settings").font(.title)
                    Text("Each tab keeps its own content.")
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(DemoTab.settings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A pushed detail page reached from the Buttons playground via NavigationLink.
struct ButtonInfoView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("About Buttons")
            Text("A Button runs its action when tapped.")
            Text("This page was pushed onto the NavigationStack and can be popped with Back.")
        }
        .navigationTitle("Button Info")
    }
}
