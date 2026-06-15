// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// Qt-specific harness for the shared ShapeRenderingTests: an offscreen QImage + QPainter driving the
// real QtToolkit.drawShape. No display or QApplication needed (raster QPainter is self-contained).

import CQt
@testable import HopQt
import HopUI

enum ShapeToolkit { static let name = "qt" }

/// An offscreen raster canvas backed by a white QImage. `finish()` must run before reading pixels.
final class ShapeCanvas {
    private let image: UnsafeMutableRawPointer
    private let painter: UnsafeMutableRawPointer

    init(width: Int, height: Int) {
        image = hopqt_image_new(Int32(width), Int32(height))!
        painter = hopqt_image_begin(image)!
    }
    deinit { hopqt_image_free(image) }

    @MainActor func draw(_ spec: ShapeSpec, frameWidth: Double, frameHeight: Double, bleedX: Double = 0, bleedY: Double = 0) {
        QtToolkit.drawShape(spec, frameWidth: frameWidth, frameHeight: frameHeight, bleedX: bleedX, bleedY: bleedY, painter: painter)
    }

    @MainActor func translated(_ dx: Double, _ dy: Double, _ body: () -> Void) {
        hopqt_painter_save(painter)
        hopqt_painter_translate(painter, dx, dy)
        body()
        hopqt_painter_restore(painter)
    }

    func finish() { hopqt_image_end(painter) }  // ending the painter flushes to the image

    func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let v = hopqt_image_pixel(image, Int32(x), Int32(y))  // 0xAARRGGBB
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255, Double((v >> 24) & 0xff) / 255)
    }

    func savePNG(_ path: String) -> Bool { hopqt_image_save_png(image, path) == 1 }
}
