// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// HopUI's geometry types. On Apple platforms we use the real CoreGraphics types (so the Shape/Path
// surface matches SwiftUI exactly and bridges straight to CGContext/NSBezierPath). On non-Apple
// platforms (e.g. Linux/Windows where the GTK4 toolkit runs) CoreGraphics doesn't exist, but
// swift-corelibs Foundation vends API-compatible CGFloat / CGPoint / CGSize / CGRect (struct CGFloat,
// like Apple). Re-export those rather than declaring our own — defining duplicate CGRect/etc. types
// here collides with Foundation's once any consumer imports both HopUI and Foundation, producing
// "'CGRect' is ambiguous for type lookup" errors.

#if canImport(CoreGraphics)
@_exported import CoreGraphics
#else
@_exported import Foundation
#endif
