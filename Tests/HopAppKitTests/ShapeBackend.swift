// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// AppKit-specific harness for the shared ShapeRenderingTests: an offscreen NSBitmapImageRep + CoreGraphics
// context driving the real AppKitBackend.drawShape. Needs no on-screen window; 1× (unlike a Retina
// cacheDisplay rep), so pixel coordinates are direct.

#if canImport(AppKit)
import AppKit
@testable import HopAppKit
import HopUI

enum ShapeBackend { static let name = "appkit" }

/// An offscreen raster canvas backed by a white NSBitmapImageRep, drawn into via its CoreGraphics context.
final class ShapeCanvas {
    private let rep: NSBitmapImageRep
    private let nsContext: NSGraphicsContext
    private var ctx: CGContext { nsContext.cgContext }

    init(width: Int, height: Int) {
        rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        nsContext = NSGraphicsContext(bitmapImageRep: rep)!
        let c = nsContext.cgContext
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip to top-left / y-down so AppKitBackend.drawShape (which assumes the flipped on-screen view)
        // matches, and `colorAt(x:y:)` (top-left) reads consistently with the GTK4/Qt canvases.
        c.translateBy(x: 0, y: CGFloat(height))
        c.scaleBy(x: 1, y: -1)
    }

    @MainActor func draw(_ spec: ShapeSpec, frameWidth: Double, frameHeight: Double, bleedX: Double = 0, bleedY: Double = 0) {
        AppKitBackend.drawShape(spec, in: CGRect(x: bleedX, y: bleedY, width: frameWidth, height: frameHeight), context: ctx)
    }

    @MainActor func translated(_ dx: Double, _ dy: Double, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(dx), y: CGFloat(dy))
        body()
        ctx.restoreGState()
    }

    func finish() {}

    func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    func savePNG(_ path: String) -> Bool {
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
    }
}
#endif
