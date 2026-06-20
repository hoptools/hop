// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Prints a PNG's pixel dimensions and an (approximate, capped) distinct-color count, space-separated:
//
//     <width> <height> <colors>
//
// Used by screenshot-playgrounds.sh on macOS to (a) report a screenshot's dimensions for the CI summary
// and (b) decide whether a captured window actually drew content: an unrendered window is one flat color
// (a handful of distinct values, mostly anti-aliasing on the rounded corners), while any real HopUI page —
// always carrying the sidebar list, toolbar, and text — has hundreds. This avoids a dependency on
// ImageMagick (`identify`), which GitHub's macOS runners do not ship. Usage: imgstat <png>

import CoreGraphics
import Foundation
import ImageIO

func fail() -> Never { print("0 0 0"); exit(1) }

guard CommandLine.arguments.count >= 2 else { fail() }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail() }

let w = cg.width, h = cg.height
guard w > 0, h > 0 else { print("\(w) \(h) 0"); exit(0) }

// Redraw into a known RGBA8 buffer so we read pixels directly (no per-pixel CoreGraphics calls).
let bytesPerRow = w * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: bytesPerRow, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("\(w) \(h) 0"); exit(0)
}
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// Count distinct colors over a sample of the pixels, early-exiting once we have plenty — we only need to
// distinguish "flat/blank" (a few) from "real content" (hundreds+), not an exact histogram.
let total = w * h
let stride = max(1, total / 200_000)   // sample up to ~200k pixels
let cap = 4096
var seen = Set<UInt32>()
var i = 0
while i < total {
    let p = i * 4
    let rgba = (UInt32(pixels[p]) << 24) | (UInt32(pixels[p + 1]) << 16)
             | (UInt32(pixels[p + 2]) << 8) | UInt32(pixels[p + 3])
    seen.insert(rgba)
    if seen.count >= cap { break }
    i += stride
}
print("\(w) \(h) \(seen.count)")
