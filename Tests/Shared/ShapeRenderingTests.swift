// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// SHARED across the AppKit, GTK4, and Qt test targets via a symlink (Tests/<Backend>Tests/
// ShapeRenderingTests.swift -> ../Shared/ShapeRenderingTests.swift). It renders shapes through each
// backend's REAL drawing path into a headless offscreen canvas and inspects the resulting pixels —
// CoreGraphics (AppKit), Cairo (GTK4), and QPainter (Qt) all produce the same output, with no display.
//
// The backend-specific details live in a sibling `ShapeBackend.swift` in each test folder, which defines
// a `ShapeCanvas` (offscreen surface + the backend's drawShape + pixel read + PNG save) and a
// `ShapeBackend.name`. This file stays entirely backend-agnostic.

import Testing
import HopUI

@MainActor @Suite struct ShapeRenderingTests {

    /// Assert a pixel's RGB matches a color within tolerance (alpha ignored — backgrounds are opaque white).
    private func assertClose(_ got: (r: Double, g: Double, b: Double, a: Double), _ color: Color,
                             tol: Double = 0.12, _ message: String = "") {
        #expect(abs(got.r - color.red) <= tol)
        #expect(abs(got.g - color.green) <= tol)
        #expect(abs(got.b - color.blue) <= tol)
    }

    @Test func testFilledRectangleCoversBounds() throws {
        let canvas = ShapeCanvas(width: 60, height: 60)
        canvas.draw(ShapeSpec(path: { Rectangle().path(in: $0) }, fill: .red), frameWidth: 60, frameHeight: 60)
        canvas.finish()
        // A filled rectangle paints every interior pixel red.
        assertClose(canvas.pixel(30, 30), .red, "rect center")
        assertClose(canvas.pixel(4, 4), .red, "rect corner")
    }

    @Test func testFilledCircleInsideAndOutside() throws {
        let canvas = ShapeCanvas(width: 60, height: 60)
        canvas.draw(ShapeSpec(path: { Circle().path(in: $0) }, fill: .blue), frameWidth: 60, frameHeight: 60)
        canvas.finish()
        assertClose(canvas.pixel(30, 30), .blue, "circle center")
        // The corner is outside the inscribed circle → the white background shows through.
        assertClose(canvas.pixel(2, 2), .white, "circle corner is background")
    }

    @Test func testStrokedCircleIsHollow() throws {
        let canvas = ShapeCanvas(width: 60, height: 60)
        canvas.draw(ShapeSpec(path: { Circle().path(in: $0) }, fill: nil, stroke: .green, lineWidth: 6),
                    frameWidth: 60, frameHeight: 60)
        canvas.finish()
        // Center stays background (not filled); the left rim carries the stroke color.
        assertClose(canvas.pixel(30, 30), .white, "stroked circle center is background")
        assertClose(canvas.pixel(1, 30), .green, tol: 0.2, "rim color")
    }

    @Test func testRoundedRectCornerIsRounded() throws {
        let canvas = ShapeCanvas(width: 60, height: 60)
        canvas.draw(ShapeSpec(path: { RoundedRectangle(cornerRadius: 20).path(in: $0) }, fill: .orange),
                    frameWidth: 60, frameHeight: 60)
        canvas.finish()
        // The very corner is clipped away by the rounding (background), but the center is filled.
        assertClose(canvas.pixel(30, 30), .orange, "rounded-rect center")
        assertClose(canvas.pixel(1, 1), .white, "rounded-rect corner is clipped")
    }

    /// Write a montage PNG for visual inspection (also exercises ellipse/capsule/transform/custom path).
    @Test func testWriteMontagePNG() throws {
        let cell = 90, pad = 14, count = 8
        let canvas = ShapeCanvas(width: pad + (cell + pad) * count, height: cell + 2 * pad)

        let triangle: @MainActor (CGRect) -> Path = { rect in
            Path { p in
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.closeSubpath()
            }
        }
        let specs: [ShapeSpec] = [
            ShapeSpec(path: { Rectangle().path(in: $0) }, fill: .red),
            ShapeSpec(path: { RoundedRectangle(cornerRadius: 16).path(in: $0) }, fill: .orange),
            ShapeSpec(path: { Circle().path(in: $0) }, fill: .blue),
            ShapeSpec(path: { Capsule().path(in: $0) }, fill: .green),
            ShapeSpec(path: { Ellipse().path(in: $0) }, fill: .purple),
            ShapeSpec(path: { Circle().path(in: $0) }, fill: nil, stroke: .pink, lineWidth: 6),
            ShapeSpec(path: { Rectangle().path(in: $0) }, fill: .indigo, rotation: .degrees(45), scaleX: 0.8, scaleY: 0.8),
            ShapeSpec(path: triangle, fill: .teal),
        ]
        for (i, spec) in specs.enumerated() {
            canvas.translated(Double(pad + i * (cell + pad)), Double(pad)) {
                canvas.draw(spec, frameWidth: Double(cell), frameHeight: Double(cell))
            }
        }
        canvas.finish()
        #expect(canvas.savePNG("/tmp/hop-shapes-montage-\(ShapeBackend.name).png"))
    }
}
