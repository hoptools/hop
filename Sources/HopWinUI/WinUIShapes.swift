// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import WinUI
import WindowsFoundation
import HopUI
import Foundation  // cos/sin for arc endpoint computation

// Translates a HopUI ``Path`` (already resolved for a concrete rect) into a WinUI XAML `Geometry`, so a
// `.shape` widget can be drawn with the platform-native vector pipeline — a `Microsoft.UI.Xaml.Shapes.Path`
// whose `Data` is this geometry. Higher-level primitives (rect / rounded-rect / ellipse) map to their exact
// XAML geometry (`RectangleGeometry` / `EllipseGeometry`) rather than a Bézier approximation; freeform
// move/line/curve/quad/arc runs become a `PathGeometry` of `PathFigure`s. All sub-geometries are collected
// into one `GeometryGroup` so a single fill/stroke covers the whole shape, matching CoreGraphics/Cairo/QPainter.
enum WinUIShapeBuilder {
    private static func pt(_ p: CGPoint) -> WindowsFoundation.Point {
        WindowsFoundation.Point(x: Float(p.x), y: Float(p.y))
    }

    static func geometry(for path: HopUI.Path) -> WinUI.Geometry {
        let group = WinUI.GeometryGroup()
        group.fillRule = .nonzero

        // Freeform segments accumulate into PathFigures; primitives are appended to the group directly.
        var figures: [WinUI.PathFigure] = []
        var figure: WinUI.PathFigure?

        func closeFigure(_ closed: Bool) {
            if let f = figure { f.isClosed = closed; figures.append(f) }
            figure = nil
        }
        func startFigure(at point: WindowsFoundation.Point) {
            closeFigure(false)
            let f = WinUI.PathFigure()
            f.startPoint = point
            figure = f
        }
        func append(_ segment: WinUI.PathSegment) {
            if figure == nil { startFigure(at: WindowsFoundation.Point(x: 0, y: 0)) }
            figure?.segments.append(segment)
        }

        for element in path.elements {
            switch element {
            case .move(let p):
                startFigure(at: pt(p))
            case .line(let p):
                let s = WinUI.LineSegment(); s.point = pt(p); append(s)
            case .quadCurve(let p, let c):
                let s = WinUI.QuadraticBezierSegment(); s.point1 = pt(c); s.point2 = pt(p); append(s)
            case .curve(let p, let c1, let c2):
                let s = WinUI.BezierSegment(); s.point1 = pt(c1); s.point2 = pt(c2); s.point3 = pt(p); append(s)
            case .closeSubpath:
                closeFigure(true)
            case .rect(let r):
                let g = WinUI.RectangleGeometry()
                g.rect = WindowsFoundation.Rect(x: Float(r.minX), y: Float(r.minY), width: Float(r.width), height: Float(r.height))
                group.children.append(g)
            case .roundedRect(let r, let cs):
                // WinUI's RectangleGeometry has no corner radii (unlike WPF), so build the rounded rect as a
                // closed figure of straight edges + quarter-circle arc corners.
                group.children.append(roundedRectGeometry(r, cornerSize: cs))
            case .ellipse(let r):
                let g = WinUI.EllipseGeometry()
                g.center = WindowsFoundation.Point(x: Float(r.midX), y: Float(r.midY))
                g.radiusX = Double(r.width / 2)
                g.radiusY = Double(r.height / 2)
                group.children.append(g)
            case .arc(let center, let radius, let start, let end, let clockwise):
                let startPt = CGPoint(x: center.x + radius * CGFloat(cos(start.radians)),
                                      y: center.y + radius * CGFloat(sin(start.radians)))
                let endPt = CGPoint(x: center.x + radius * CGFloat(cos(end.radians)),
                                    y: center.y + radius * CGFloat(sin(end.radians)))
                startFigure(at: pt(startPt))
                let s = WinUI.ArcSegment()
                s.point = pt(endPt)
                s.size = WindowsFoundation.Size(width: Float(radius), height: Float(radius))
                s.sweepDirection = clockwise ? .clockwise : .counterclockwise
                s.isLargeArc = abs(end.radians - start.radians) > Double.pi
                append(s)
            }
        }
        closeFigure(false)

        if !figures.isEmpty {
            let pathGeometry = WinUI.PathGeometry()
            for f in figures { pathGeometry.figures.append(f) }
            group.children.append(pathGeometry)
        }
        return group
    }

    /// A rounded rectangle as a closed `PathGeometry` (edges as lines, corners as quarter-circle arcs).
    private static func roundedRectGeometry(_ r: CGRect, cornerSize cs: CGSize) -> WinUI.PathGeometry {
        let rx = Float(min(cs.width, r.width / 2)), ry = Float(min(cs.height, r.height / 2))
        let x = Float(r.minX), y = Float(r.minY), w = Float(r.width), h = Float(r.height)
        let figure = WinUI.PathFigure()
        figure.startPoint = WindowsFoundation.Point(x: x + rx, y: y)
        figure.isClosed = true

        func line(_ px: Float, _ py: Float) {
            let s = WinUI.LineSegment(); s.point = WindowsFoundation.Point(x: px, y: py); figure.segments.append(s)
        }
        func arc(_ px: Float, _ py: Float) {
            let s = WinUI.ArcSegment()
            s.point = WindowsFoundation.Point(x: px, y: py)
            s.size = WindowsFoundation.Size(width: rx, height: ry)
            s.sweepDirection = .clockwise
            figure.segments.append(s)
        }
        line(x + w - rx, y);      arc(x + w, y + ry)        // top edge → top-right corner
        line(x + w, y + h - ry);  arc(x + w - rx, y + h)    // right edge → bottom-right corner
        line(x + rx, y + h);      arc(x, y + h - ry)        // bottom edge → bottom-left corner
        line(x, y + ry);          arc(x + rx, y)            // left edge → top-left corner

        let geometry = WinUI.PathGeometry()
        geometry.figures.append(figure)
        return geometry
    }
}
