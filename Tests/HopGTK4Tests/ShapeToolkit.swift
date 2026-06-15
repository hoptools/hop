// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// GTK4-specific harness for the shared ShapeRenderingTests: an offscreen Cairo image surface driving
// the real GTK4Toolkit.drawShape. Cairo image surfaces need no display.

import CGTK4
@testable import HopGTK4
import HopUI

enum ShapeToolkit { static let name = "gtk4" }

/// An offscreen raster canvas backed by a white Cairo ARGB32 image surface.
final class ShapeCanvas {
    private let surface: OpaquePointer
    private let cr: OpaquePointer

    init(width: Int, height: Int) {
        surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height))!
        cr = cairo_create(surface)!
        cairo_set_source_rgb(cr, 1, 1, 1)
        cairo_paint(cr)
    }
    deinit { cairo_destroy(cr); cairo_surface_destroy(surface) }

    @MainActor func draw(_ spec: ShapeSpec, frameWidth: Double, frameHeight: Double, bleedX: Double = 0, bleedY: Double = 0) {
        GTK4Toolkit.drawShape(spec, frameWidth: frameWidth, frameHeight: frameHeight, bleedX: bleedX, bleedY: bleedY, cr: cr)
    }

    @MainActor func translated(_ dx: Double, _ dy: Double, _ body: () -> Void) {
        cairo_save(cr)
        cairo_translate(cr, dx, dy)
        body()
        cairo_restore(cr)
    }

    func finish() { cairo_surface_flush(surface) }

    func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        cairo_surface_flush(surface)
        guard let data = cairo_image_surface_get_data(surface) else { return (0, 0, 0, 0) }
        let stride = Int(cairo_image_surface_get_stride(surface))
        let o = y * stride + x * 4  // premultiplied BGRA, little-endian
        return (Double(data[o + 2]) / 255, Double(data[o + 1]) / 255, Double(data[o]) / 255, Double(data[o + 3]) / 255)
    }

    func savePNG(_ path: String) -> Bool { cairo_surface_write_to_png(surface, path) == CAIRO_STATUS_SUCCESS }
}
