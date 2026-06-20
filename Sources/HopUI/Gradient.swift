// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(Foundation)
import Foundation  // CGFloat/CGRect/CGPoint + trig for color interpolation
#endif

// SwiftUI's gradient views (`LinearGradient`/`RadialGradient`/`AngularGradient`). Each is a `View` that
// fills its frame with a smooth multi-color blend, and can also be used as a `Shape` fill
// (`Circle().fill(LinearGradient(...))`). They reuse HopUI's shape pipeline: a gradient view is a
// rectangle-path `ShapeComponent` whose `ShapeSpec.gradient` the backend paints with its native gradient
// API (CoreGraphics / Cairo / QGradient / WinUI brushes). Angular is native only on Qt (`QConicalGradient`);
// AppKit/GTK render it by hand (their draw surfaces are CG/Cairo), and WinUI approximates it (no conic brush).

/// A point in the unit square — (0,0) top-leading … (1,1) bottom-trailing. Mirrors SwiftUI's `UnitPoint`;
/// gradients place their start/end points and centers relative to the filled rect with it.
public nonisolated struct UnitPoint: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }

    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)

    /// The absolute point this unit point denotes within `rect`.
    public func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
}

/// An ordered list of color stops. Mirrors SwiftUI's `Gradient`.
public struct Gradient: Equatable, Sendable {
    /// A color at a normalized location (0…1) along the gradient.
    public struct Stop: Equatable, Sendable {
        public var color: Color
        public var location: CGFloat
        public init(color: Color, location: CGFloat) { self.color = color; self.location = location }
    }

    public var stops: [Stop]
    public init(stops: [Stop]) { self.stops = stops }

    /// Evenly spaces `colors` from 0 to 1.
    public init(colors: [Color]) {
        switch colors.count {
        case 0: stops = []
        case 1: stops = [Stop(color: colors[0], location: 0), Stop(color: colors[0], location: 1)]
        default:
            let last = CGFloat(colors.count - 1)
            stops = colors.enumerated().map { Stop(color: $1, location: CGFloat($0) / last) }
        }
    }
}

/// The backend-facing description of a gradient fill, carried on ``ShapeSpec/gradient``. Backends read
/// `kind` + `stops` and paint with their native gradient API.
public struct GradientSpec {
    public enum Kind: Equatable {
        case linear(start: UnitPoint, end: UnitPoint)
        case radial(center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat)
        case angular(center: UnitPoint, startAngle: Angle, endAngle: Angle)
    }
    public var kind: Kind
    public var stops: [Gradient.Stop]

    public init(kind: Kind, stops: [Gradient.Stop]) { self.kind = kind; self.stops = stops }

    /// Resolve any adaptive stop colors (`.primary`/…) for the scheme. Called when the node is built.
    func resolved(in scheme: ColorScheme) -> GradientSpec {
        GradientSpec(kind: kind,
                     stops: stops.map { Gradient.Stop(color: $0.color.resolve(in: scheme), location: $0.location) })
    }

    /// The interpolated color at fraction `t` (0…1) — used by the AppKit/GTK manual conic renderers.
    public func color(at t: CGFloat) -> Color {
        guard let first = stops.first else { return .clear }
        if t <= first.location { return first.color }
        guard let last = stops.last else { return first.color }
        if t >= last.location { return last.color }
        for i in 1..<stops.count {
            let lo = stops[i - 1], hi = stops[i]
            if t <= hi.location {
                let span = hi.location - lo.location
                let f = span > 0 ? (t - lo.location) / span : 0
                return Color(red: lo.color.red + (hi.color.red - lo.color.red) * Double(f),
                             green: lo.color.green + (hi.color.green - lo.color.green) * Double(f),
                             blue: lo.color.blue + (hi.color.blue - lo.color.blue) * Double(f),
                             opacity: lo.color.opacity + (hi.color.opacity - lo.color.opacity) * Double(f))
            }
        }
        return last.color
    }
}

// MARK: - Gradient views

/// A gradient view, as a rectangle-path shape carrying the gradient. Shared by the three gradient types.
@MainActor private func gradientNode(_ spec: GradientSpec, _ context: RenderContext) -> RenderNode {
    let resolved = spec.resolved(in: currentEnvironment().colorScheme)
    let shape = ShapeSpec(path: { rect in Path { $0.addRect(rect) } }, gradient: resolved)
    return RenderNode(id: context.id, component: ShapeComponent(spec: shape))
}

/// A linear (axial) gradient between two unit points. Mirrors SwiftUI's `LinearGradient`.
public struct LinearGradient: View, PrimitiveView {
    let spec: GradientSpec
    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {
        spec = GradientSpec(kind: .linear(start: startPoint, end: endPoint), stops: gradient.stops)
    }
    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(colors: colors), startPoint: startPoint, endPoint: endPoint)
    }
    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(stops: stops), startPoint: startPoint, endPoint: endPoint)
    }
    public typealias Body = Never
    public var body: Never { fatalError("LinearGradient has no body") }
    func makeNode(_ context: RenderContext) -> RenderNode { gradientNode(spec, context) }
}

/// A radial gradient from `startRadius` to `endRadius` about `center`. Mirrors SwiftUI's `RadialGradient`.
public struct RadialGradient: View, PrimitiveView {
    let spec: GradientSpec
    public init(gradient: Gradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        spec = GradientSpec(kind: .radial(center: center, startRadius: startRadius, endRadius: endRadius), stops: gradient.stops)
    }
    public init(colors: [Color], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.init(gradient: Gradient(colors: colors), center: center, startRadius: startRadius, endRadius: endRadius)
    }
    public init(stops: [Gradient.Stop], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.init(gradient: Gradient(stops: stops), center: center, startRadius: startRadius, endRadius: endRadius)
    }
    public typealias Body = Never
    public var body: Never { fatalError("RadialGradient has no body") }
    func makeNode(_ context: RenderContext) -> RenderNode { gradientNode(spec, context) }
}

/// An angular (conic / sweep) gradient about `center`. Mirrors SwiftUI's `AngularGradient`. Equal
/// start/end angles mean a full 360° sweep.
public struct AngularGradient: View, PrimitiveView {
    let spec: GradientSpec
    public init(gradient: Gradient, center: UnitPoint = .center, startAngle: Angle = .zero, endAngle: Angle = .zero) {
        let (s, e) = startAngle.radians == endAngle.radians ? (Angle.degrees(0), Angle.degrees(360)) : (startAngle, endAngle)
        spec = GradientSpec(kind: .angular(center: center, startAngle: s, endAngle: e), stops: gradient.stops)
    }
    public init(colors: [Color], center: UnitPoint = .center, startAngle: Angle = .zero, endAngle: Angle = .zero) {
        self.init(gradient: Gradient(colors: colors), center: center, startAngle: startAngle, endAngle: endAngle)
    }
    public init(stops: [Gradient.Stop], center: UnitPoint = .center, startAngle: Angle = .zero, endAngle: Angle = .zero) {
        self.init(gradient: Gradient(stops: stops), center: center, startAngle: startAngle, endAngle: endAngle)
    }
    /// Full-sweep variant rotated to start at `angle`. Mirrors SwiftUI's `AngularGradient(gradient:center:angle:)`.
    public init(gradient: Gradient, center: UnitPoint = .center, angle: Angle) {
        spec = GradientSpec(kind: .angular(center: center, startAngle: angle, endAngle: angle + .degrees(360)), stops: gradient.stops)
    }
    public init(colors: [Color], center: UnitPoint = .center, angle: Angle) {
        self.init(gradient: Gradient(colors: colors), center: center, angle: angle)
    }
    public typealias Body = Never
    public var body: Never { fatalError("AngularGradient has no body") }
    func makeNode(_ context: RenderContext) -> RenderNode { gradientNode(spec, context) }
}

// MARK: - Gradient as a Shape fill

extension Shape {
    /// Fills the shape with a linear gradient. Mirrors `Shape.fill(_:)` with a gradient `ShapeStyle`.
    public func fill(_ gradient: LinearGradient) -> some View { _filled(gradient.spec) }
    /// Fills the shape with a radial gradient.
    public func fill(_ gradient: RadialGradient) -> some View { _filled(gradient.spec) }
    /// Fills the shape with an angular gradient.
    public func fill(_ gradient: AngularGradient) -> some View { _filled(gradient.spec) }

    private func _filled(_ gradient: GradientSpec) -> some View {
        _ShapeNodeModifier(content: self) { spec in
            spec.gradient = gradient
            spec.fill = nil
            spec.stroke = nil
        }
    }
}
