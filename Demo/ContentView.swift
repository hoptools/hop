// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The SAME ContentView builds against either HopUI or Apple's SwiftUI — no shims. Each executable
// target defines exactly one HOPUI_TOOLKIT_* constant (see Package.swift); the SwiftUI one imports
// SwiftUI, the others import HopUI, whose API mirrors SwiftUI's.
#if HOPUI_TOOLKIT_SWIFTUI
import SwiftUI
import AppKit  // NSImage, to load the bundled demo image (SwiftUI has no plain-file Image init)
#else
import HopUI
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

    func toggleColorScheme() {
        colorScheme = colorScheme == .dark ? .light : .dark
    }
}

/// The playgrounds shown in the sidebar selector, modeled on skipapp-showcase. Each demonstrates one
/// of the components HopUI implements so far. They are grouped into desktop UI categories by
/// ``sidebarTree`` and presented through an ``OutlineGroup`` tree selector.
enum Playground: String, CaseIterable, Hashable {
    case slider, button, toggle, stepper, textField, secureField, progress
    case text, accessibility, label, link
    case shapes, images
    case layout, disclosure, groupBox, form, tabs
    case observable, menus

    var title: String {
        switch self {
        case .slider: return "Slider"
        case .button: return "Buttons"
        case .toggle: return "Toggle"
        case .stepper: return "Stepper"
        case .textField: return "Text Field"
        case .secureField: return "Secure Field"
        case .progress: return "Progress"
        case .text: return "Text Styles"
        case .accessibility: return "Accessibility"
        case .label: return "Label"
        case .link: return "Link"
        case .shapes: return "Shapes"
        case .images: return "Images"
        case .layout: return "Layout"
        case .disclosure: return "Disclosure"
        case .groupBox: return "GroupBox"
        case .form: return "Form"
        case .tabs: return "Tabs"
        case .observable: return "Observable"
        case .menus: return "Menus"
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

/// One node in the sidebar's hierarchical selector: either a category header (with `children`) or a leaf
/// that maps to a ``Playground``. `id` is a `String` so the whole tree selects against a single
/// `Binding<String?>` — a category's id (`cat.*`) maps to no playground; a leaf's id is the playground's
/// raw value. Drives the ``OutlineGroup`` tree in both HopUI and SwiftUI builds.
struct SidebarItem: Identifiable, Hashable {
    let id: String
    let title: String
    var children: [SidebarItem]? = nil

    /// A leaf row for a playground.
    init(_ playground: Playground) {
        self.id = playground.rawValue
        self.title = playground.title
    }

    /// A category header grouping child rows.
    init(category id: String, _ title: String, _ children: [SidebarItem]) {
        self.id = "cat.\(id)"
        self.title = title
        self.children = children
    }
}

/// The sidebar's tree of categories → playgrounds, organized into logical desktop UI groups.
let sidebarTree: [SidebarItem] = [
    SidebarItem(category: "controls", "Controls", [
        SidebarItem(.slider), SidebarItem(.button), SidebarItem(.toggle), SidebarItem(.stepper),
        SidebarItem(.textField), SidebarItem(.secureField), SidebarItem(.progress),
    ]),
    SidebarItem(category: "text", "Text & Accessibility", [
        SidebarItem(.text), SidebarItem(.accessibility), SidebarItem(.label), SidebarItem(.link),
    ]),
    SidebarItem(category: "graphics", "Graphics", [
        SidebarItem(.shapes), SidebarItem(.images),
    ]),
    SidebarItem(category: "containers", "Containers", [
        SidebarItem(.layout), SidebarItem(.disclosure),
        SidebarItem(.groupBox), SidebarItem(.form), SidebarItem(.tabs),
    ]),
    SidebarItem(category: "data", "Data & Menus", [
        SidebarItem(.observable), SidebarItem(.menus),
    ]),
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

    // Playground state lives here and is handed to the playgrounds as bindings (slider/button/text) or
    // through the environment (observable), so each playground is a self-contained, reusable view.
    @State private var sliderValue = 50.0
    @State private var count = 0
    @State private var name = ""
    // Menus playground state (lifted here so it persists across re-renders, like the other playgrounds).
    @State private var flavor = Flavor.vanilla
    @State private var quantity = 1
    @State private var lastMenuAction = "—"
    // Tier-1 control state (lifted here, handed to playgrounds as bindings — like the other playgrounds).
    @State private var wifiOn = true
    @State private var notificationsOn = false
    @State private var stepperQuantity = 3
    @State private var password = ""

    public init() {}

    public var body: some View {
        NavigationSplitView {
            // A hierarchical OutlineGroup tree selector (native NSOutlineView / GtkTreeListModel /
            // QTreeWidget). Selection binds to the node id string: a leaf's id is a Playground raw value;
            // a category header maps to no playground (placeholder detail).
            List(selection: Binding<String?>(
                get: { selection?.rawValue },
                set: { selection = $0.flatMap(Playground.init(rawValue:)); navPath = [] }
            )) {
                OutlineGroup(sidebarTree, children: \.children) { item in
                    Text(item.title)
                }
            }
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
                ButtonPlayground(count: $count)
            } else if selection == .toggle {
                TogglePlayground(wifi: $wifiOn, notifications: $notificationsOn)
            } else if selection == .stepper {
                StepperPlayground(quantity: $stepperQuantity)
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
            } else if selection == .accessibility {
                AccessibilityPlayground()
            } else if selection == .shapes {
                ShapesPlayground()
            } else if selection == .images {
                ImagePlayground()
            } else if selection == .menus {
                MenuPlayground(flavor: $flavor, quantity: $quantity, lastAction: $lastMenuAction)
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
            } else {
                LayoutPlayground()
            }
        } else {
            Text("Select a playground from the sidebar")
        }
    }
}

// MARK: - Playgrounds

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
    @Binding var count: Int
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
    @Binding var wifi: Bool
    @Binding var notifications: Bool
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
    @Binding var quantity: Int
    var body: some View {
        VStack(spacing: 16) {
            Text("Increment or decrement a bound value (0…10)")
            Stepper("Quantity: \(quantity)", value: $quantity, in: 0 ... 10)
                .frame(width: 260)
            Text("You picked \(quantity)")
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
    @Binding var flavor: Flavor
    @Binding var quantity: Int
    @Binding var lastAction: String

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
    var body: some View {
        TabView {
            VStack(spacing: 10) {
                Text("Welcome to HopUI").font(.title)
                Text("A native SwiftUI for the desktop.")
            }
            .tabItem { Text("Home") }

            VStack(spacing: 10) {
                Text("Browse").font(.title)
                Text("Switch tabs to change this pane.")
            }
            .tabItem { Text("Browse") }

            VStack(spacing: 10) {
                Text("Settings").font(.title)
                Text("Each tab keeps its own content.")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
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
