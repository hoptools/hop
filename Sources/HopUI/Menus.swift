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
        let entries = menuEntries(from: evaluate(content, context.appending(0)))
        return RenderNode(id: context.id, kind: .menu, menu: MenuContent(label: label, entries: entries))
    }
}

/// Extract drop-down entries from already-evaluated content nodes: buttons become actions, separators
/// become dividers, and nested `.menu` nodes become submenus (recursively).
func menuEntries(from nodes: [RenderNode]) -> [MenuEntry] {
    var entries: [MenuEntry] = []
    for node in nodes {
        switch node.kind {
        case .button:
            entries.append(.button(title: node.patch.title ?? "", action: node.action ?? {}))
        case .separator:
            entries.append(.separator)
        case .menu:
            entries.append(.submenu(title: node.menu?.label ?? "", entries: node.menu?.entries ?? []))
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
        RenderNode(id: context.id, kind: .separator)
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
        let nodes = evaluate(content, context.appending(0))
        var options: [String] = []
        var tags: [AnyHashable] = []
        for (index, node) in nodes.enumerated() {
            options.append(node.patch.text ?? node.patch.title ?? "")
            tags.append(node.tag ?? AnyHashable(index))  // fall back to position when untagged
        }
        let selectedIndex = tags.firstIndex(of: AnyHashable(selection.wrappedValue))
        let binding = selection
        let spec = PickerSpec(title: title, options: options, selectedIndex: selectedIndex) { index in
            guard index >= 0, index < tags.count, let value = tags[index].base as? SelectionValue else { return }
            binding.wrappedValue = value
        }
        var patch = WidgetPatch()
        patch.accessibilityLabel = title  // popups show the selection, not the title; expose it to AX
        return RenderNode(id: context.id, kind: .picker, patch: patch, picker: spec)
    }
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
        var node = evaluate(content, context.appending(0)).first ?? RenderNode(id: context.id, kind: .label)
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
