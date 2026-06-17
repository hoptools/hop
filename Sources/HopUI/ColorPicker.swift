// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// Backend-agnostic payload for a `.colorPicker` ``RenderNode``. Like ``DatePickerSpec`` it is reapplied
/// on every reconcile (not `Equatable`): it carries the current color, whether opacity is editable, and
/// the change callback that writes back to the bound ``Color``.
public struct ColorPickerSpec {
    public let title: String
    public let color: Color
    public let supportsOpacity: Bool
    public let onChange: @MainActor (Color) -> Void

    public init(title: String, color: Color, supportsOpacity: Bool,
                onChange: @escaping @MainActor (Color) -> Void) {
        self.title = title
        self.color = color
        self.supportsOpacity = supportsOpacity
        self.onChange = onChange
    }
}

/// A control for choosing a color, mirroring SwiftUI's `ColorPicker`. Bound to a ``Color`` via a
/// ``Binding`` and backed by each toolkit's native color control (NSColorWell on AppKit, a
/// GtkColorButton on GTK4, a swatch button that opens a QColorDialog on Qt).
///
/// Like SwiftUI it renders the title as a leading label beside the swatch; the native color control
/// itself is the `_ColorPickerControl` leaf.
public struct ColorPicker: View {
    let title: String
    let selection: Binding<Color>
    let supportsOpacity: Bool

    // MARK: - SwiftUI-matching initializers

    public init<S: StringProtocol>(_ title: S, selection: Binding<Color>, supportsOpacity: Bool = true) {
        self.title = String(title)
        self.selection = selection
        self.supportsOpacity = supportsOpacity
    }

    private var control: _ColorPickerControl {
        _ColorPickerControl(title: title, selection: selection, supportsOpacity: supportsOpacity)
    }

    @ViewBuilder public var body: some View {
        if title.isEmpty {
            control
        } else {
            HStack(spacing: 12) {
                Text(title)
                control
            }
        }
    }
}

/// The native color control leaf carrying a ``ColorPickerSpec``. ``ColorPicker`` wraps this with its label.
struct _ColorPickerControl: View, PrimitiveView {
    let title: String
    let selection: Binding<Color>
    let supportsOpacity: Bool

    typealias Body = Never
    var body: Never { fatalError("_ColorPickerControl has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let binding = selection
        let spec = ColorPickerSpec(title: title, color: selection.wrappedValue,
                             supportsOpacity: supportsOpacity) { binding.wrappedValue = $0 }
        var patch = WidgetPatch()
        patch.accessibilityLabel = title   // cross-cutting; applied alongside the component
        return RenderNode(id: context.id, component: ColorPickerComponent(spec: spec),
                          patch: patch)
    }
}

/// The open component for ``ColorPicker``. Public so backend color-picker renderers can read its spec.
public struct ColorPickerComponent: WidgetComponent {
    public let spec: ColorPickerSpec
    public init(spec: ColorPickerSpec) { self.spec = spec }
    public var widgetKey: WidgetKey { .colorPicker }
    public var role: WidgetRole { .leaf }
}
