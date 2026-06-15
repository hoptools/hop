// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Common accessibility modifiers, mirroring SwiftUI. Each is a per-view modifier that records its
// value on the node's patch; the toolkits then apply it to the toolkit-idiomatic accessibility API
// (NSAccessibility / GtkAccessible / QAccessible), so assistive technologies see it.

/// Characteristics of an accessibility element, mirroring SwiftUI's `AccessibilityTraits`.
public nonisolated struct AccessibilityTraits: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let isButton = AccessibilityTraits(rawValue: 1 << 0)
    public static let isHeader = AccessibilityTraits(rawValue: 1 << 1)
    public static let isImage = AccessibilityTraits(rawValue: 1 << 2)
    public static let isSelected = AccessibilityTraits(rawValue: 1 << 3)
    public static let isStaticText = AccessibilityTraits(rawValue: 1 << 4)
    public static let isLink = AccessibilityTraits(rawValue: 1 << 5)
}

/// A per-view modifier that records accessibility information on the wrapped view's node.
struct _AccessibilityModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let apply: (inout WidgetPatch) -> Void

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let nodes = evaluate(content, context.appending(0))
        var node = nodes.first ?? RenderNode(id: context.id, kind: .vstack, children: nodes)
        apply(&node.patch)
        return node
    }
}

extension View {
    /// A succinct label describing the view to assistive technologies (overrides the visible text).
    /// Mirrors SwiftUI's `.accessibilityLabel(_:)`.
    public func accessibilityLabel(_ label: String) -> some View {
        _AccessibilityModifier(content: self) { $0.accessibilityLabel = label }
    }

    /// The value an assistive technology reads for the view (e.g. "4 out of 5 stars"). Mirrors
    /// SwiftUI's `.accessibilityValue(_:)`.
    public func accessibilityValue(_ value: String) -> some View {
        _AccessibilityModifier(content: self) { $0.accessibilityValue = value }
    }

    /// A hint describing the result of performing the view's action. Mirrors SwiftUI's
    /// `.accessibilityHint(_:)`.
    public func accessibilityHint(_ hint: String) -> some View {
        _AccessibilityModifier(content: self) { $0.accessibilityHint = hint }
    }

    /// A stable, non-localized identifier for the view (useful for UI tests). Mirrors SwiftUI's
    /// `.accessibilityIdentifier(_:)`.
    public func accessibilityIdentifier(_ identifier: String) -> some View {
        _AccessibilityModifier(content: self) { $0.accessibilityIdentifier = identifier }
    }

    /// Hides the view from assistive technologies (or shows it). Mirrors SwiftUI's
    /// `.accessibilityHidden(_:)`.
    public func accessibilityHidden(_ hidden: Bool) -> some View {
        _AccessibilityModifier(content: self) { $0.accessibilityHidden = hidden }
    }

    /// Adds accessibility traits (e.g. `.isHeader`, `.isButton`) to the view. Mirrors SwiftUI's
    /// `.accessibilityAddTraits(_:)`.
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View {
        _AccessibilityModifier(content: self) { $0.accessibilityTraits = ($0.accessibilityTraits ?? []).union(traits) }
    }
}
