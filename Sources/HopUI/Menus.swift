// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// In-content drop-down menus, mirroring SwiftUI's `Menu` (an action drop-down) and `Picker` (a
// selection drop-down bound to state), plus `Divider` and the `.tag(_:)` modifier. These are distinct
// from the app menu BAR (see Menu.swift / Scene.commands): they live inside the view tree and map to
// each toolkit's native popup control (NSPopUpButton / GtkMenuButton+GtkDropDown / QPushButton+QMenu+QComboBox).

// MARK: - Drop-down Menu (action menu)

/// One entry in a drop-down ``Menu``: a button that runs an action, a separator, or a nested submenu.
public enum MenuEntry {
    case button(title: String, action: @MainActor () -> Void)
    case separator
    indirect case submenu(title: String, entries: [MenuEntry])
}

/// The contents of a drop-down ``Menu`` — its button label plus its entries. Carried on a `.menu`
/// `RenderNode` and applied via `configureMenu` (not `Equatable`; reapplied each reconcile, like ``ListSpec``).
public struct MenuContent {
    public let label: String
    public let entries: [MenuEntry]
    public init(label: String, entries: [MenuEntry]) {
        self.label = label
        self.entries = entries
    }
}

/// A button that presents a drop-down of choices when clicked. Mirrors SwiftUI's `Menu`. The content
/// is a `@ViewBuilder` of `Button`s (actions), `Divider`s (separators), and nested `Menu`s (submenus).
public struct Menu<Content: View>: View, PrimitiveView {
    let label: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.label = title
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError("Menu has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let entries = menuEntries(from: evaluateResolved(content, context.appending(0)))
        return RenderNode(id: context.id,
                          component: MenuComponent(content: MenuContent(label: label, entries: entries)))
    }
}

/// The open component for ``Menu``. Public so backend menu renderers can read its content.
public struct MenuComponent: WidgetComponent {
    public let content: MenuContent
    public init(content: MenuContent) { self.content = content }
    public var widgetKey: WidgetKey { .menu }
    public var role: WidgetRole { .leaf }
}

/// Extract drop-down entries from already-evaluated content nodes: buttons become actions, separators
/// become dividers, and nested `.menu` nodes become submenus (recursively).
func menuEntries(from nodes: [RenderNode]) -> [MenuEntry] {
    var entries: [MenuEntry] = []
    for node in nodes {
        switch node.component.widgetKey {
        case .button:
            entries.append(.button(title: node.effectivePatch.title ?? "", action: node.effectiveAction ?? {}))
        case .separator:
            entries.append(.separator)
        case .menu:
            entries.append(.submenu(title: node.effectiveMenu?.label ?? "", entries: node.effectiveMenu?.entries ?? []))
        default:
            break
        }
    }
    return entries
}

/// A visual divider. In a ``Menu`` it is a separator line between entries; elsewhere it is a thin rule.
/// Mirrors SwiftUI's `Divider`.
public struct Divider: View, PrimitiveView {
    public init() {}
    public typealias Body = Never
    public var body: Never { fatalError("Divider has no body") }
    func makeNode(_ context: RenderContext) -> RenderNode {
        RenderNode(id: context.id,
                   component: PrimitiveLeafComponent(.separator))
    }
}

// MARK: - Picker (selection drop-down)

/// Everything a toolkit needs to drive a selection popup: the option labels, which one is selected,
/// and a callback when the user picks an index. Carried on a `.picker` `RenderNode`.
public struct PickerSpec {
    public let title: String
    public let options: [String]
    public let selectedIndex: Int?
    public let onSelect: @MainActor (Int) -> Void
    public init(title: String, options: [String], selectedIndex: Int?, onSelect: @escaping @MainActor (Int) -> Void) {
        self.title = title
        self.options = options
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
    }
}

/// A drop-down for choosing one value from a set, bound to state. Mirrors SwiftUI's menu-style `Picker`.
/// Options are the `@ViewBuilder` content's children, each carrying a `.tag(_:)` value matched against
/// `selection`.
public struct Picker<SelectionValue: Hashable, Content: View>: View, PrimitiveView {
    let title: String
    let selection: Binding<SelectionValue>
    let content: Content

    public init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.selection = selection
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError("Picker has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let nodes = evaluateResolved(content, context.appending(0))
        var options: [String] = []
        var tags: [AnyHashable] = []
        for (index, node) in nodes.enumerated() {
            options.append(node.effectivePatch.text ?? node.effectivePatch.title ?? "")
            tags.append(node.tag ?? AnyHashable(index))  // fall back to position when untagged
        }
        let selectedIndex = tags.firstIndex(of: AnyHashable(selection.wrappedValue))
        let binding = selection
        let spec = PickerSpec(title: title, options: options, selectedIndex: selectedIndex) { index in
            guard index >= 0, index < tags.count, let value = tags[index].base as? SelectionValue else { return }
            binding.wrappedValue = value
        }
        // The style — read from the (graph-tracked) environment — selects the native implementation. It is
        // part of the component's `widgetKey`, so changing the style recreates the widget (a `.menu` popup
        // and a `.segmented` control are different native widgets, not reconfigurations of each other).
        let style = currentEnvironment().pickerStyle
        return RenderNode(id: context.id, component: PickerComponent(style: style, spec: spec))
    }
}

/// How a ``Picker`` is presented. Each case maps to a different native widget (and possibly a different
/// layout role), so it is part of the component's ``WidgetKey``. Mirrors SwiftUI's `PickerStyle`.
public enum PickerStyle: String, Hashable, Sendable, CaseIterable {
    case automatic, menu, segmented, radioGroup, inline
}

/// How a ``Toggle`` is presented — each case is a different native widget (switch / checkbox / push-toggle
/// button), so it is part of the component's ``WidgetKey`` (a style change recreates the widget). Mirrors
/// SwiftUI's `ToggleStyle` cases. (`switch` is a Swift keyword, hence the backticks.)
public enum ToggleStyle: String, Hashable, Sendable, CaseIterable {
    case automatic, `switch`, checkbox, button
}

public extension WidgetKey {
    /// A `Toggle`'s key for a given style — the native impl identity, so a style change recreates the widget.
    /// Backends register one renderer per `.toggle(style)`. Parallels `.picker(_:)`.
    static func toggle(_ style: ToggleStyle) -> WidgetKey { WidgetKey("toggle.\(style.rawValue)") }
}

public extension WidgetKey {
    /// A `Picker`'s key for a given style — the implementation identity (a `.menu` popup and a `.segmented`
    /// control are different native widgets), so a style change recreates the widget. Backends register one
    /// renderer per `.picker(style)`.
    static func picker(_ style: PickerStyle) -> WidgetKey { WidgetKey("picker.\(style.rawValue)") }
}

/// The open ``WidgetComponent`` for ``Picker``. The canonical example of style-driven implementation
/// variance: `widgetKey` encodes the style, so each style dispatches to its own backend renderer and a
/// style change tears down + recreates the native widget. Every style is a `.leaf` — the renderer builds a
/// single self-sizing native widget (pop-up / segmented control / radio-button group) with no HopUI child
/// nodes, so it's measured by the renderer's natural size (a `.native` role would collapse to zero height
/// in a stack, since that role is for fill-the-space composites the container gives a concrete proposal).
/// Selection lives in `@State`, so it survives the recreate. Public so backend picker renderers can read it.
public struct PickerComponent: WidgetComponent {
    public let style: PickerStyle
    public let spec: PickerSpec
    public init(style: PickerStyle, spec: PickerSpec) { self.style = style; self.spec = spec }
    public var widgetKey: WidgetKey { .picker(style) }
    public var role: WidgetRole { .leaf }
}

extension View {
    /// Sets the presentation style of `Picker`s within this view. Mirrors SwiftUI's `.pickerStyle(_:)`.
    /// Flows through the (graph-tracked) environment, so a style change re-evaluates only the pickers that
    /// read it.
    public func pickerStyle(_ style: PickerStyle) -> some View { environment(\.pickerStyle, style) }
}

// MARK: - .tag

/// Attaches an identity value to a view so a ``Picker`` can match it against its selection. Mirrors
/// SwiftUI's `.tag(_:)`. The tag is metadata only — it does not affect rendering.
struct _TaggedView<Content: View>: View, PrimitiveView {
    let content: Content
    let tag: AnyHashable

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first ?? RenderNode(id: context.id, component: PrimitiveLeafComponent(.label))
        node.tag = tag
        return node
    }
}

extension View {
    /// Sets a unique tag value used to match this view against a ``Picker``'s selection. Mirrors SwiftUI.
    public func tag<V: Hashable>(_ value: V) -> some View {
        _TaggedView(content: self, tag: AnyHashable(value))
    }
}
