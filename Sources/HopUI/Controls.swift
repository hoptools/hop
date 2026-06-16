// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(Foundation)
import Foundation  // URL / Process (Link opens URLs via the platform opener)
#endif

// Tier-1 controls layered on the existing primitives + a couple of native widgets. Toggle and
// SecureField are backed by native widgets (`.toggle` / `.secureField`); Stepper, Label, and Link
// compose from existing primitives. Every call site compiles against HopUI and Apple's SwiftUI.

// MARK: - Toggle

/// A boolean on/off control. Mirrors SwiftUI's `Toggle`. Composed as the label + a trailing native
/// switch (NSSwitch / GtkSwitch / QCheckBox); reading the binding re-renders when it changes elsewhere.
public struct Toggle<Label: View>: View {
    let isOn: Binding<Bool>
    let label: Label

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    public var body: some View {
        HStack(spacing: 8) {
            label
            Spacer()
            _ToggleControl(isOn: isOn)
        }
    }
}

extension Toggle where Label == Text {
    public init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

/// The bare native switch produced by ``Toggle`` (label-less); not constructed directly.
struct _ToggleControl: View, PrimitiveView {
    let isOn: Binding<Bool>

    typealias Body = Never
    var body: Never { fatalError("_ToggleControl has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let binding = isOn
        return RenderNode(id: context.id, kind: .toggle,
                          component: PrimitiveLeafComponent(WidgetKey("toggle"),
                              patch: WidgetPatch(boolValue: isOn.wrappedValue),
                              onChangeBool: { binding.wrappedValue = $0 }))
    }
}

// MARK: - Stepper

/// A control that increments/decrements a bound value, mirroring SwiftUI's `Stepper(_:value:in:step:)`.
/// Composed as a label + a −/+ button pair (native buttons on every toolkit); the value itself is shown
/// by the caller in the label, as in SwiftUI.
public struct Stepper<V: Strideable>: View {
    let title: String
    let value: Binding<V>
    let range: ClosedRange<V>
    let step: V.Stride

    public init(_ title: String, value: Binding<V>, in range: ClosedRange<V>, step: V.Stride = 1) {
        self.title = title
        self.value = value
        self.range = range
        self.step = step
    }

    public var body: some View {
        let binding = value
        let bounds = range
        let step = step
        return HStack(spacing: 8) {
            Text(title)
            Spacer()
            Button("−") {
                let next = binding.wrappedValue.advanced(by: -step)
                binding.wrappedValue = next < bounds.lowerBound ? bounds.lowerBound : next
            }
            Button("+") {
                let next = binding.wrappedValue.advanced(by: step)
                binding.wrappedValue = next > bounds.upperBound ? bounds.upperBound : next
            }
        }
    }
}

// MARK: - SecureField

/// A masked single-line text entry bound to a `String`. Mirrors SwiftUI's `SecureField(_:text:)`.
/// Like ``TextField`` but the characters are hidden by the native widget.
public struct SecureField: View, PrimitiveView {
    let placeholder: String
    let text: Binding<String>

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self.text = text
    }

    public typealias Body = Never
    public var body: Never { fatalError("SecureField has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let binding = text
        return RenderNode(id: context.id, kind: .secureField,
                          component: PrimitiveLeafComponent(WidgetKey("secureField"),
                              patch: WidgetPatch(value: text.wrappedValue, placeholder: placeholder),
                              onChange: { binding.wrappedValue = $0 }))
    }
}

// MARK: - Label

/// A title paired with a leading icon. Mirrors SwiftUI's `Label(_:systemImage:)` / `Label(_:image:)`.
/// Composed as an `HStack { Image; Text }`.
public struct Label: View {
    let icon: Image
    let title: String

    public init(_ title: String, systemImage: String) {
        self.title = title
        self.icon = Image(systemName: systemImage)
    }

    public init(_ title: String, image: String) {
        self.title = title
        self.icon = Image(image)
    }

    public var body: some View {
        HStack(spacing: 6) {
            icon
            Text(title)
        }
    }
}

// MARK: - Link

/// A control that opens a URL when activated. Mirrors SwiftUI's `Link(_:destination:)`. Composed as a
/// `Button` whose action opens the URL with the platform opener (`open` on macOS, `xdg-open` on Linux).
public struct Link: View {
    let title: String
    let destination: URL

    public init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    public var body: some View {
        let url = destination
        return Button(title) { hopOpenURL(url) }
    }
}

/// Open a URL with the platform's default handler. HopUI core has no toolkit dependency, so this shells
/// out to the standard opener rather than using NSWorkspace / gtk_show_uri / QDesktopServices.
func hopOpenURL(_ url: URL) {
    #if os(macOS)
    let opener = "/usr/bin/open"
    #else
    let opener = "/usr/bin/xdg-open"
    #endif
    let task = Process()
    task.executableURL = URL(fileURLWithPath: opener)
    task.arguments = [url.absoluteString]
    try? task.run()
}
