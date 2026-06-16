// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Runtime-free unit tests for the WinUI toolkit. These exercise only the toolkit's pure value→value
// conversions (HopUI Color/Font → WinRT structs), which never activate a WinRT class, so they run in a
// plain test process without the Windows App Runtime bootstrap. The live XAML mapping (control creation,
// geometry, layout) is exercised by building and launching `hop-demo-winui`.

import Testing
import HopUI
@testable import HopWinUI

@MainActor @Suite struct WinUIConversionTests {

    @Test func colorChannelsMapToEightBit() {
        let opaqueRed = WinUIToolkit.uwpColor(HopUI.Color(red: 1, green: 0, blue: 0.5, opacity: 1))
        #expect(opaqueRed.a == 255)
        #expect(opaqueRed.r == 255)
        #expect(opaqueRed.g == 0)
        #expect(opaqueRed.b == 128)  // 0.5 * 255 = 127.5, rounded to 128
    }

    @Test func colorOpacityMapsToAlpha() {
        let translucent = WinUIToolkit.uwpColor(HopUI.Color(red: 0, green: 0, blue: 0, opacity: 0.5))
        #expect(translucent.a == 128)
    }

    @Test func colorChannelsClampToValidRange() {
        // Defensive: a hand-built out-of-range component must not overflow the UInt8 channel.
        let clamped = WinUIToolkit.uwpColor(HopUI.Color(red: 2, green: -1, blue: 0.5, opacity: 1))
        #expect(clamped.r == 255)
        #expect(clamped.g == 0)
    }

    @Test func fontWeightMapsToNumericValue() {
        #expect(WinUIToolkit.fontWeight(.regular).weight == 400)
        #expect(WinUIToolkit.fontWeight(.semibold).weight == 600)
        #expect(WinUIToolkit.fontWeight(.bold).weight == 700)
        #expect(WinUIToolkit.fontWeight(.black).weight == 900)
    }
}
