// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(Foundation)
import Foundation  // sin/cos for the transform-bleed bounding box
#endif

// SwiftUI's Shape system: a `Shape` produces a `Path` for a given rect; the backend draws it with its
// native vector API (CoreGraphics / Cairo / QPainter). Built-ins (Rectangle, RoundedRectangle, Circle,
// Capsule, Ellipse) and custom `Path`s are all `Shape`s, and the same fill/stroke/frame/transform
// modifiers apply to all of them.

/// Everything a backend needs to draw a shape: how to build its path for a given rect, plus fill /
/// stroke style and an (offset, rotation, scale) transform applied around the shape's center.
public struct ShapeSpec {
    public let path: @MainActor (CGRect) -> Path
    public var fill: Color?
    public var stroke: Color?
    public var lineWidth: CGFloat
    public var offset: CGSize
    public var rotation: Angle
    public var scaleX: CGFloat
    public var scaleY: CGFloat

    public init(path: @escaping @MainActor (CGRect) -> Path,
                fill: Color? = nil, stroke: Color? = nil, lineWidth: CGFloat = 1,
                offset: CGSize = .zero, rotation: Angle = .zero, scaleX: CGFloat = 1, scaleY: CGFloat = 1) {
        self.path = path
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
        self.offset = offset
        self.rotation = rotation
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    /// How far the center-anchored transform (offset/rotation/scale) pushes the frame rectangle beyond
    /// its `width`×`height` bounds, per edge (all ≥ 0). SwiftUI and AppKit draw this overflow outside the
    /// frame without clipping; toolkits whose widgets clip to their bounds (Qt's `QWidget`, GTK4's
    /// `GtkDrawingArea`) must enlarge the drawing surface by this much so the transformed shape isn't cut off.
    public func transformBleed(width: CGFloat, height: CGFloat) -> (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        let cx = width / 2, cy = height / 2
        let cosT = CGFloat(cos(rotation.radians)), sinT = CGFloat(sin(rotation.radians))
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height)] {
            // Same order the backends draw with: scale, then rotate, then offset — about the center.
            let sx = (corner.x - cx) * scaleX, sy = (corner.y - cy) * scaleY
            let px = cx + offset.width + (sx * cosT - sy * sinT)
            let py = cy + offset.height + (sx * sinT + sy * cosT)
            minX = min(minX, px); minY = min(minY, py)
            maxX = max(maxX, px); maxY = max(maxY, py)
        }
        return (max(0, -minX), max(0, -minY), max(0, maxX - width), max(0, maxY - height))
    }
}

/// A 2D shape that can be drawn and styled. Mirrors SwiftUI's `Shape`.
public protocol Shape: View {
    func path(in rect: CGRect) -> Path
}

extension Shape {
    /// A shape's view is the `_ShapeView` that renders its path; conforming types only implement `path(in:)`.
    public var body: _ShapeView {
        let shape = self
        return _ShapeView(spec: ShapeSpec(path: { rect in shape.path(in: rect) }))
    }
}

/// The view that renders a shape's path. Produced by `Shape.body`; not constructed directly.
public struct _ShapeView: View, PrimitiveView {
    let spec: ShapeSpec
    init(spec: ShapeSpec) { self.spec = spec }

    public typealias Body = Never
    public var body: Never { fatalError("_ShapeView has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var resolved = spec
        // A bare shape fills with the inherited foreground color (default black), like SwiftUI.
        if resolved.fill == nil, resolved.stroke == nil {
            resolved.fill = EnvironmentStore.current.foregroundColor ?? .black
        }
        return RenderNode(id: context.id, kind: .shape, shape: resolved)
    }
}

// MARK: - Built-in shapes

public struct Rectangle: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path { $0.addRect(rect) } }
}

public struct RoundedRectangle: Shape {
    public var cornerSize: CGSize
    public init(cornerRadius: CGFloat) { cornerSize = CGSize(width: cornerRadius, height: cornerRadius) }
    public init(cornerSize: CGSize) { self.cornerSize = cornerSize }
    public func path(in rect: CGRect) -> Path { Path { $0.addRoundedRect(in: rect, cornerSize: cornerSize) } }
}

public struct Circle: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let diameter = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                            width: diameter, height: diameter)
        return Path { $0.addEllipse(in: square) }
    }
}

public struct Ellipse: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path { $0.addEllipse(in: rect) } }
}

public struct Capsule: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        return Path { $0.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius)) }
    }
}

/// A `Path` is itself a `Shape` (drawn in its own coordinate space). Mirrors SwiftUI.
extension Path: Shape {
    public func path(in rect: CGRect) -> Path { self }
}

// MARK: - Shape styling & transform modifiers

/// A per-node modifier that mutates the shape (and/or patch) of the view it wraps. Used by fill /
/// stroke / frame / rotationEffect / offset / scaleEffect.
struct _ShapeNodeModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let modify: (inout RenderNode) -> Void

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        let nodes = evaluate(content, context.appending(0))
        var node = nodes.first ?? RenderNode(id: context.id, kind: .vstack, children: nodes)
        modify(&node)
        return node
    }
}

extension Shape {
    /// Fills the shape with a color. Mirrors SwiftUI's `Shape.fill(_:)`.
    public func fill(_ color: Color) -> some View {
        _ShapeNodeModifier(content: self) { node in
            node.shape?.fill = color
            node.shape?.stroke = nil
        }
    }

    /// Strokes the shape's outline. Mirrors SwiftUI's `Shape.stroke(_:lineWidth:)`.
    public func stroke(_ color: Color, lineWidth: CGFloat = 1) -> some View {
        _ShapeNodeModifier(content: self) { node in
            node.shape?.stroke = color
            node.shape?.fill = nil
            node.shape?.lineWidth = lineWidth
        }
    }
}

extension View {
    /// Rotates the view's shape around its center. Mirrors SwiftUI's `.rotationEffect(_:)`.
    public func rotationEffect(_ angle: Angle) -> some View {
        _ShapeNodeModifier(content: self) { node in
            if node.shape != nil { node.shape!.rotation = node.shape!.rotation + angle }
        }
    }

    /// Offsets the view's shape. Mirrors SwiftUI's `.offset(x:y:)`.
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View {
        _ShapeNodeModifier(content: self) { node in
            if node.shape != nil {
                node.shape!.offset = CGSize(width: node.shape!.offset.width + x,
                                            height: node.shape!.offset.height + y)
            }
        }
    }

    /// Scales the view's shape around its center. Mirrors SwiftUI's `.scaleEffect(_:)`.
    public func scaleEffect(_ scale: CGFloat) -> some View {
        scaleEffect(x: scale, y: scale)
    }

    /// Scales the view's shape with independent x/y factors. Mirrors SwiftUI's `.scaleEffect(x:y:)`.
    public func scaleEffect(x: CGFloat = 1, y: CGFloat = 1) -> some View {
        _ShapeNodeModifier(content: self) { node in
            if node.shape != nil {
                node.shape!.scaleX *= x
                node.shape!.scaleY *= y
            }
        }
    }
}
