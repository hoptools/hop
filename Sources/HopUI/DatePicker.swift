// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which calendar components a ``DatePicker`` edits. Mirrors SwiftUI's `DatePickerComponents`, so the
/// same call sites (`.date`, `.hourAndMinute`, `[.date, .hourAndMinute]`) compile against both.
public struct DatePickerComponents: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// The hour and minute.
    public static let hourAndMinute = DatePickerComponents(rawValue: 1 << 0)
    /// The month, day, and year.
    public static let date = DatePickerComponents(rawValue: 1 << 1)
}

/// The visual style of a ``DatePicker`` — the subset of SwiftUI's `.datePickerStyle(_:)` options that
/// maps cleanly onto every toolkit's native control.
public enum DatePickerStyle: Sendable {
    /// The toolkit default (a compact field, with a stepper / popover calendar).
    case automatic
    /// A compact field with a stepper or popover calendar.
    case compact
    /// An always-visible calendar (plus time spinners when time is shown), like SwiftUI's graphical style.
    case graphical
    /// A plain editable field.
    case field
}

/// Backend-agnostic payload for a `.datePicker` ``RenderNode``. Like ``PickerSpec`` it is reapplied on
/// every reconcile (not `Equatable`): it carries the current value, optional bounds, the edited
/// components, the style, and the change callback that writes back to the bound `Date`.
public struct DatePickerSpec {
    public let title: String
    public let date: Date
    public let minDate: Date?
    public let maxDate: Date?
    public let components: DatePickerComponents
    public let style: DatePickerStyle
    public let onChange: @MainActor (Date) -> Void

    public init(title: String, date: Date, minDate: Date? = nil, maxDate: Date? = nil,
                components: DatePickerComponents, style: DatePickerStyle,
                onChange: @escaping @MainActor (Date) -> Void) {
        self.title = title
        self.date = date
        self.minDate = minDate
        self.maxDate = maxDate
        self.components = components
        self.style = style
        self.onChange = onChange
    }
}

/// A control for choosing a date and/or time, mirroring SwiftUI's `DatePicker`. Bound to a `Date` via a
/// ``Binding`` and backed by each toolkit's native date control (NSDatePicker on AppKit, a
/// GtkCalendar + hour/minute spinners on GTK4, a QDateTimeEdit on Qt).
///
/// Like SwiftUI it renders the title as a leading label next to the control; the native date control
/// itself is the `_DatePickerControl` leaf below.
public struct DatePicker: View {
    let title: String
    let selection: Binding<Date>
    let minDate: Date?
    let maxDate: Date?
    let components: DatePickerComponents
    var style: DatePickerStyle

    // MARK: - SwiftUI-matching initializers

    public init<S: StringProtocol>(_ title: S, selection: Binding<Date>,
                                   displayedComponents: DatePickerComponents = [.hourAndMinute, .date]) {
        self.init(text: String(title), selection: selection, min: nil, max: nil, components: displayedComponents)
    }

    public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, in range: ClosedRange<Date>,
                                   displayedComponents: DatePickerComponents = [.hourAndMinute, .date]) {
        self.init(text: String(title), selection: selection,
                  min: range.lowerBound, max: range.upperBound, components: displayedComponents)
    }

    public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, in range: PartialRangeFrom<Date>,
                                   displayedComponents: DatePickerComponents = [.hourAndMinute, .date]) {
        self.init(text: String(title), selection: selection,
                  min: range.lowerBound, max: nil, components: displayedComponents)
    }

    public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, in range: PartialRangeThrough<Date>,
                                   displayedComponents: DatePickerComponents = [.hourAndMinute, .date]) {
        self.init(text: String(title), selection: selection,
                  min: nil, max: range.upperBound, components: displayedComponents)
    }

    private init(text: String, selection: Binding<Date>, min: Date?, max: Date?,
                 components: DatePickerComponents, style: DatePickerStyle = .automatic) {
        self.title = text
        self.selection = selection
        self.minDate = min
        self.maxDate = max
        self.components = components
        self.style = style
    }

    /// Set the visual style. Mirrors SwiftUI's `.datePickerStyle(_:)`.
    public func datePickerStyle(_ style: DatePickerStyle) -> DatePicker {
        var copy = self
        copy.style = style
        return copy
    }

    private var control: _DatePickerControl {
        _DatePickerControl(title: title, selection: selection, minDate: minDate, maxDate: maxDate,
                           components: components, style: style)
    }

    @ViewBuilder public var body: some View {
        if title.isEmpty {
            control
        } else {
            // Label beside the control (sized to content so it fits narrow windows without clipping).
            HStack(spacing: 12) {
                Text(title)
                control
            }
        }
    }
}

/// The native date control leaf carrying a ``DatePickerSpec``. `DatePicker` wraps this with its label.
struct _DatePickerControl: View, PrimitiveView {
    let title: String
    let selection: Binding<Date>
    let minDate: Date?
    let maxDate: Date?
    let components: DatePickerComponents
    var style: DatePickerStyle

    typealias Body = Never
    var body: Never { fatalError("_DatePickerControl has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let binding = selection
        let spec = DatePickerSpec(title: title, date: selection.wrappedValue,
                                  minDate: minDate, maxDate: maxDate,
                                  components: components, style: style) { binding.wrappedValue = $0 }
        var patch = WidgetPatch()
        patch.accessibilityLabel = title   // cross-cutting; applied alongside the component
        return RenderNode(id: context.id, component: DatePickerComponent(spec: spec),
                          patch: patch)
    }
}

/// The open component for ``DatePicker``. Public so backend date-picker renderers can read its spec.
public struct DatePickerComponent: WidgetComponent {
    public let spec: DatePickerSpec
    public init(spec: DatePickerSpec) { self.spec = spec }
    public var widgetKey: WidgetKey { .datePicker }
    public var role: WidgetRole { .leaf }
}
