// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// HopUI's geometry types. On Apple platforms we use the real CoreGraphics types (so the Shape/Path
// surface matches SwiftUI exactly and bridges straight to CGContext/NSBezierPath). On non-Apple
// platforms (e.g. Linux/Windows where the GTK4 backend runs) CoreGraphics doesn't exist, so we
// provide API-compatible CGFloat / CGPoint / CGSize / CGRect implementations of our own.

#if canImport(CoreGraphics)
@_exported import CoreGraphics
#else

public typealias CGFloat = Double

public struct CGPoint: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat = 0, y: CGFloat = 0) { self.x = x; self.y = y }
    public init(x: Int, y: Int) { self.x = CGFloat(x); self.y = CGFloat(y) }
    public static let zero = CGPoint(x: 0, y: 0)
}

public struct CGSize: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public init(width: CGFloat = 0, height: CGFloat = 0) { self.width = width; self.height = height }
    public init(width: Int, height: Int) { self.width = CGFloat(width); self.height = CGFloat(height) }
    public static let zero = CGSize(width: 0, height: 0)
}

public struct CGRect: Equatable, Sendable {
    public var origin: CGPoint
    public var size: CGSize
    public init(origin: CGPoint, size: CGSize) { self.origin = origin; self.size = size }
    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.init(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
    public static let zero = CGRect(x: 0, y: 0, width: 0, height: 0)

    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var midX: CGFloat { origin.x + size.width / 2 }
    public var midY: CGFloat { origin.y + size.height / 2 }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }

    public func insetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: origin.x + dx, y: origin.y + dy, width: size.width - 2 * dx, height: size.height - 2 * dy)
    }
}

#endif
