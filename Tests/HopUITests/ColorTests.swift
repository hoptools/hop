// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

@MainActor private struct AdaptiveHost: View {
    let scheme: ColorScheme
    var body: some View {
        Text("label").foregroundStyle(.primary)
            .environment(\.colorScheme, scheme)
    }
}

@MainActor @Suite struct ColorTests {
    @Test func testAdaptiveColorsResolveToSchemeLabel() {
        // primary: full-opacity label — black in light, white in dark.
        #expect(Color.primary.resolve(in: .light) == Color(red: 0, green: 0, blue: 0, opacity: 1.0))
        #expect(Color.primary.resolve(in: .dark) == Color(red: 1, green: 1, blue: 1, opacity: 1.0))
        // secondary: the label at reduced prominence (same hue, lower opacity).
        #expect(Color.secondary.resolve(in: .light) == Color(red: 0, green: 0, blue: 0, opacity: 0.5))
        #expect(Color.secondary.resolve(in: .dark) == Color(red: 1, green: 1, blue: 1, opacity: 0.5))
        // The hierarchy is progressively fainter.
        #expect(Color.tertiary.resolve(in: .light).opacity > Color.quaternary.resolve(in: .light).opacity)
    }

    @Test func testConcreteColorsAreSchemeIndependent() {
        #expect(Color.red.resolve(in: .light) == .red)
        #expect(Color.red.resolve(in: .dark) == .red)
    }

    @Test func testForegroundStyleResolvesAgainstEnvironmentScheme() throws {
        // `.foregroundStyle(.primary)` on a Text resolves against the ambient `\.colorScheme` at build time.
        let light = MockToolkit()
        runHopApp(AdaptiveHost(scheme: .light), toolkit: light, title: "t")
        #expect(light.widgets.first { $0.text == "label" }?.foregroundColor
                == Color(red: 0, green: 0, blue: 0, opacity: 1.0))

        let dark = MockToolkit()
        runHopApp(AdaptiveHost(scheme: .dark), toolkit: dark, title: "t")
        #expect(dark.widgets.first { $0.text == "label" }?.foregroundColor
                == Color(red: 1, green: 1, blue: 1, opacity: 1.0))
    }
}
