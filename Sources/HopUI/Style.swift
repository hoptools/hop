// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Color and Font value types plus the common styling modifiers — `.foregroundStyle`, `.background`,
// `.font`, `.fontWeight` — mirroring SwiftUI. Foreground color and font are environment-inherited
// (a `Text` reads the ambient values), so styling a container styles its text descendants; a
// background is a per-view layer.

/// A color, mirroring SwiftUI's `Color`. Components are 0...1. Backends convert to NSColor / GdkRGBA
/// / QColor.
public nonisolated struct Color: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    public static let red = Color(red: 1.0, green: 0.23, blue: 0.19)
    public static let orange = Color(red: 1.0, green: 0.58, blue: 0.0)
    public static let yellow = Color(red: 1.0, green: 0.8, blue: 0.0)
    public static let green = Color(red: 0.2, green: 0.78, blue: 0.35)
    public static let mint = Color(red: 0.0, green: 0.78, blue: 0.75)
    public static let teal = Color(red: 0.19, green: 0.69, blue: 0.78)
    public static let cyan = Color(red: 0.35, green: 0.78, blue: 0.98)
    public static let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
    public static let indigo = Color(red: 0.35, green: 0.34, blue: 0.84)
    public static let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
    public static let pink = Color(red: 1.0, green: 0.18, blue: 0.33)
    public static let brown = Color(red: 0.64, green: 0.52, blue: 0.37)
    public static let gray = Color(red: 0.56, green: 0.56, blue: 0.58)
    public static let black = Color(red: 0.0, green: 0.0, blue: 0.0)
    public static let white = Color(red: 1.0, green: 1.0, blue: 1.0)
    public static let clear = Color(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.0)

    /// `rgba(...)` form used by the GTK4 CSS and Qt stylesheet backends.
    public var cssRGBA: String {
        "rgba(\(Int((red * 255).rounded())),\(Int((green * 255).rounded())),\(Int((blue * 255).rounded())),\(opacity))"
    }
}

/// A font, mirroring SwiftUI's `Font`. Carries a point size, a weight, and an optional custom family
/// (nil = the system font).
public nonisolated struct Font: Equatable, Sendable {
    public var size: Double
    public var weight: Weight
    public var family: String?

    public enum Weight: Equatable, Sendable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

        /// CSS numeric weight (100...900) for the GTK4/Qt backends.
        public var cssValue: Int {
            switch self {
            case .ultraLight: return 100
            case .thin: return 200
            case .light: return 300
            case .regular: return 400
            case .medium: return 500
            case .semibold: return 600
            case .bold: return 700
            case .heavy: return 800
            case .black: return 900
            }
        }
    }

    public init(size: Double, weight: Weight = .regular, family: String? = nil) {
        self.size = size
        self.weight = weight
        self.family = family
    }

    /// The system font at the given size and weight. Mirrors `Font.system(size:weight:)`.
    public static func system(size: Double, weight: Weight = .regular) -> Font {
        Font(size: size, weight: weight, family: nil)
    }

    /// A custom font family at the given size. Mirrors `Font.custom(_:size:)`.
    public static func custom(_ name: String, size: Double) -> Font {
        Font(size: size, weight: .regular, family: name)
    }

    // A few semantic fonts (mapped to fixed sizes/weights for the desktop MVP).
    public static let largeTitle = Font(size: 34, weight: .regular)
    public static let title = Font(size: 28, weight: .regular)
    public static let title2 = Font(size: 22, weight: .regular)
    public static let title3 = Font(size: 20, weight: .regular)
    public static let headline = Font(size: 17, weight: .semibold)
    public static let body = Font(size: 17, weight: .regular)
    public static let callout = Font(size: 16, weight: .regular)
    public static let subheadline = Font(size: 15, weight: .regular)
    public static let footnote = Font(size: 13, weight: .regular)
    public static let caption = Font(size: 12, weight: .regular)

    func with(weight: Weight) -> Font {
        Font(size: size, weight: weight, family: family)
    }
}

/// A modifier that draws a color behind a view. Per-view (not inherited). Mirrors a common form of
/// SwiftUI's `.background`.
struct _BackgroundModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let color: Color

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        // Wrap the content in a container sized to the content (a single-child zstack hugs its child), with
        // the fill on the container. This paints the background behind the content AS-MODIFIED — i.e. it
        // covers any `.padding`/`.frame` applied before `.background`, matching SwiftUI (where `.background`
        // draws behind the view so far). A flat patch on the content node would only cover the inner content.
        let child = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id + ".bg", kind: .vstack)
        return RenderNode(id: context.id, kind: .zstack, patch: WidgetPatch(backgroundColor: color),
                          children: [child], layout: LayoutInfo(alignment: .center))
    }
}

extension View {
    /// Sets the foreground (text) color for this view and its descendants. Mirrors SwiftUI's
    /// `.foregroundStyle(_:)` for a `Color` style.
    public func foregroundStyle(_ color: Color) -> some View {
        _EnvironmentWritingView(content: self) { $0.foregroundColor = color }
    }

    /// Sets the default font for text in this view and its descendants. Mirrors SwiftUI's `.font(_:)`.
    public func font(_ font: Font?) -> some View {
        _EnvironmentWritingView(content: self) { $0.font = font }
    }

    /// Overrides the font weight for text in this view and its descendants. Mirrors SwiftUI's
    /// `.fontWeight(_:)`.
    public func fontWeight(_ weight: Font.Weight?) -> some View {
        _EnvironmentWritingView(content: self) { $0.fontWeightOverride = weight }
    }

    /// Draws `color` behind this view. Mirrors a common form of SwiftUI's `.background(_:)`.
    public func background(_ color: Color) -> some View {
        _BackgroundModifier(content: self, color: color)
    }
}
