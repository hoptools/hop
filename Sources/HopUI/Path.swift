// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(Foundation)
import Foundation  // sin/cos for arc decomposition is not needed here, but Double math is
#endif

/// A geometric angle, mirroring SwiftUI's `Angle`.
public nonisolated struct Angle: Equatable, Sendable {
    public var radians: Double
    public init(radians: Double) { self.radians = radians }
    public init(degrees: Double) { self.radians = degrees * .pi / 180 }
    public var degrees: Double { radians * 180 / .pi }

    public static let zero = Angle(radians: 0)
    public static func radians(_ r: Double) -> Angle { Angle(radians: r) }
    public static func degrees(_ d: Double) -> Angle { Angle(degrees: d) }

    public static func + (lhs: Angle, rhs: Angle) -> Angle { Angle(radians: lhs.radians + rhs.radians) }
    public static func - (lhs: Angle, rhs: Angle) -> Angle { Angle(radians: lhs.radians - rhs.radians) }
}

/// The outline of a 2D shape, mirroring SwiftUI's `Path`. It records a list of drawing elements that
/// each backend replays into its native path API (CoreGraphics / Cairo / QPainterPath).
public struct Path: Equatable {
    /// One drawing instruction. Higher-level primitives (rect/ellipse/arc) are kept intact so each
    /// backend can use its exact native equivalent rather than a Bézier approximation.
    public enum Element: Equatable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case closeSubpath
        case rect(CGRect)
        case roundedRect(CGRect, cornerSize: CGSize)
        case ellipse(in: CGRect)
        case arc(center: CGPoint, radius: CGFloat, startAngle: Angle, endAngle: Angle, clockwise: Bool)
    }

    public private(set) var elements: [Element] = []

    public init() {}

    public init(_ callback: (inout Path) -> Void) {
        var path = Path()
        callback(&path)
        self = path
    }

    public init(_ rect: CGRect) { addRect(rect) }
    public init(roundedRect rect: CGRect, cornerRadius: CGFloat) {
        addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
    }
    public init(roundedRect rect: CGRect, cornerSize: CGSize) {
        addRoundedRect(in: rect, cornerSize: cornerSize)
    }
    public init(ellipseIn rect: CGRect) { addEllipse(in: rect) }

    public mutating func move(to point: CGPoint) { elements.append(.move(to: point)) }
    public mutating func addLine(to point: CGPoint) { elements.append(.line(to: point)) }
    public mutating func addQuadCurve(to point: CGPoint, control: CGPoint) {
        elements.append(.quadCurve(to: point, control: control))
    }
    public mutating func addCurve(to point: CGPoint, control1: CGPoint, control2: CGPoint) {
        elements.append(.curve(to: point, control1: control1, control2: control2))
    }
    public mutating func closeSubpath() { elements.append(.closeSubpath) }
    public mutating func addRect(_ rect: CGRect) { elements.append(.rect(rect)) }
    public mutating func addRoundedRect(in rect: CGRect, cornerSize: CGSize) {
        elements.append(.roundedRect(rect, cornerSize: cornerSize))
    }
    public mutating func addEllipse(in rect: CGRect) { elements.append(.ellipse(in: rect)) }
    public mutating func addArc(center: CGPoint, radius: CGFloat,
                                startAngle: Angle, endAngle: Angle, clockwise: Bool) {
        elements.append(.arc(center: center, radius: radius,
                             startAngle: startAngle, endAngle: endAngle, clockwise: clockwise))
    }

    /// Appends another path's elements.
    public mutating func addPath(_ other: Path) { elements.append(contentsOf: other.elements) }
}
