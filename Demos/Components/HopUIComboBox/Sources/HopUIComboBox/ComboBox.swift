// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// HopUIComboBox — a third-party HopUI control, in a SEPARATE package, that adds a new `ComboBox` view
// backed by each toolkit's native combo box (NSComboBox / GtkComboBoxText / QComboBox / WinUI ComboBox)
// WITHOUT editing `hop`. It uses HopUI's two public extensibility seams:
//   • `HopRepresentable` — the front-end: a View that emits a `WidgetComponent` (HopUI's cross-toolkit
//     `NSViewRepresentable` analog).
//   • `WidgetComponent.makeNative(_:)` / `updateNative(_:_:)` — the back-end: the component hands each
//     backend the *raw* native widget; the backend wraps it in its own `Handle`. The package never
//     touches a backend `Handle` type.
// The per-toolkit native code lives in this package's own modules (HopUIComboBoxAppKit/GTK4/Qt/WinUI),
// each registering a native factory into `ComboBoxBackends` at startup. So this core module depends only
// on HopUI and is fully toolkit-agnostic.

import HopUI

public extension WidgetKey {
    /// The native-widget identity for a ``ComboBox`` (its own key → the reconciler never reuses it as
    /// another widget type).
    static let comboBox = WidgetKey("hopui.comboBox")
}

/// The toolkit-agnostic payload describing an *editable* combo box: the menu item titles, the current
/// text, and the callback fired whenever the text changes — whether the user typed it freely or picked a
/// menu item (selecting an item sets the text).
public struct ComboBoxSpec {
    public var items: [String]
    public var text: String
    public var onText: @MainActor (String) -> Void

    public init(items: [String], text: String, onText: @escaping @MainActor (String) -> Void) {
        self.items = items
        self.text = text
        self.onText = onText
    }
}

/// The component HopUI realizes per backend. On a backend with a registered native factory (see
/// ``ComboBoxBackends``), `makeNative` returns that toolkit's raw combo-box widget and the backend wraps
/// it; `updateNative` reconfigures it in place when the spec changes.
struct ComboBoxComponent: WidgetComponent {
    let spec: ComboBoxSpec
    var widgetKey: WidgetKey { .comboBox }
    var role: WidgetRole { .leaf }   // intrinsic-sized, like any control
    func makeNative(_ toolkit: ToolkitID) -> Any? { ComboBoxBackends.make(toolkit, spec) }
    func updateNative(_ native: Any, _ toolkit: ToolkitID) { ComboBoxBackends.update(toolkit, native, spec) }
}

/// An *editable* drop-down backed by the host toolkit's native combo box: the user can type freeform text
/// **or** pick one of the menu items (which fills in the text). The value is a plain `String` binding —
/// not a selected index — so the menu items act as suggestions rather than the only allowed values.
///
/// ```swift
/// @State private var flavor = "Vanilla"
/// ComboBox(["Vanilla", "Chocolate", "Strawberry"], text: $flavor)
/// ```
///
/// The matching per-toolkit module must be registered once at startup (e.g. `HopUIComboBoxAppKit.register()`
/// in the app's AppKit entry point).
public struct ComboBox: HopRepresentable {
    private let spec: ComboBoxSpec

    public init(_ items: [String], text: Binding<String>) {
        spec = ComboBoxSpec(items: items, text: text.wrappedValue,
                            onText: { text.wrappedValue = $0 })
    }

    public var component: any WidgetComponent { ComboBoxComponent(spec: spec) }
}

/// The per-toolkit native-widget registry. Each backend module registers a `make`/`update` pair for its
/// `ToolkitID` at startup; ``ComboBoxComponent`` dispatches through here so the core stays decoupled from
/// every backend. `make` returns the toolkit's *raw* native widget (`NSView` / `GtkWidget*` / `QWidget*`),
/// which HopUI's backend wraps into its `Handle`.
public enum ComboBoxBackends {
    public typealias Make = @MainActor (ComboBoxSpec) -> Any
    public typealias Update = @MainActor (Any, ComboBoxSpec) -> Void

    @MainActor private static var makers: [ToolkitID: Make] = [:]
    @MainActor private static var updaters: [ToolkitID: Update] = [:]

    /// Register a backend's native combo-box factory. Call once at app startup from the matching module.
    @MainActor public static func register(_ toolkit: ToolkitID, make: @escaping Make, update: @escaping Update) {
        makers[toolkit] = make
        updaters[toolkit] = update
    }

    @MainActor static func make(_ toolkit: ToolkitID, _ spec: ComboBoxSpec) -> Any? { makers[toolkit]?(spec) }
    @MainActor static func update(_ toolkit: ToolkitID, _ native: Any, _ spec: ComboBoxSpec) {
        updaters[toolkit]?(native, spec)
    }
}
