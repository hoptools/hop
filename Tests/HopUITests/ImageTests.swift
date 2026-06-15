// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import HopUI

@MainActor @Suite struct ImageTests {
    /// Render a view through the MockBackend and return the produced `.image` node's spec.
    private func imageSpec(_ view: some View) -> ImageSpec? {
        let backend = MockBackend()
        runHopApp(view, backend: backend, title: "test")
        return backend.widgets.first { $0.kind == .image }?.imageSpec
    }

    @Test func testSystemNameIsTemplateSymbol() throws {
        let spec = try #require(imageSpec(Image(systemName: "star.fill")))
        guard case .system(let name) = spec.source else { Issue.record("expected .system"); return }
        #expect(name == "star.fill")
        #expect(spec.isTemplate)        // SF Symbols default to template (tintable), like SwiftUI
        #expect(!spec.resizable)
        #expect(spec.label == "star.fill")
    }

    @Test func testNamedDecorativeAndLabel() throws {
        let named = try #require(imageSpec(Image("photo")))
        guard case .named(let n, _) = named.source else { Issue.record("expected .named"); return }
        #expect(n == "photo")
        #expect(named.label == "photo")
        #expect(!named.isTemplate)       // a named raster isn't a template by default

        #expect(try #require(imageSpec(Image(decorative: "bg"))).isDecorative)
        #expect(try #require(imageSpec(Image("photo", label: Text("My Photo")))).label == "My Photo")
    }

    @Test func testResizableAndContentModeModifiers() throws {
        #expect(try #require(imageSpec(Image(systemName: "x").resizable())).resizable)
        // Plain .resizable() leaves contentMode nil (stretch); scaledToFit/Fill/aspectRatio set it.
        #expect(try #require(imageSpec(Image(systemName: "x").resizable())).contentMode == nil)
        #expect(try #require(imageSpec(Image(systemName: "x").resizable().scaledToFit())).contentMode == .fit)
        #expect(try #require(imageSpec(Image(systemName: "x").resizable().scaledToFill())).contentMode == .fill)
        #expect(try #require(imageSpec(Image(systemName: "x").aspectRatio(contentMode: .fit))).contentMode == .fit)
    }

    @Test func testRenderingModeAndTintFromForegroundStyle() throws {
        // A template image picks up the ambient foreground as its tint (like a shape's fill / SwiftUI).
        #expect(try #require(imageSpec(Image("p").renderingMode(.template))).isTemplate)
        #expect(try #require(imageSpec(Image(systemName: "star").foregroundStyle(.red))).tint == .red)
        // A non-template (named) image is not tinted by foregroundStyle.
        #expect(try #require(imageSpec(Image("p").foregroundStyle(.red))).tint == nil)
    }

    @Test func testMeasureIntrinsicVsGreedy() {
        let backend = MockBackend()
        let natural = MockWidget(kind: .image)
        natural.imageSpec = ImageSpec(source: .system("x"), resizable: false)
        #expect(backend.measure(natural, ProposedViewSize(width: 200, height: 200)) == CGSize(width: 30, height: 20))

        let greedy = MockWidget(kind: .image)
        greedy.imageSpec = ImageSpec(source: .system("x"), resizable: true)
        #expect(backend.measure(greedy, ProposedViewSize(width: 200, height: 200)) == CGSize(width: 200, height: 200))
    }

    @Test func testReconcileReconfiguresImageWithoutRebuild() throws {
        let backend = MockBackend()
        runHopApp(ToggleImageView(), backend: backend, title: "test")
        #expect(backend.ops.contains("image:system:a"))

        backend.clearOps()
        try #require(backend.widgets.first { $0.kind == .button }).action?()
        backend.drainMainThread()
        #expect(backend.ops.contains("image:system:b"))  // the same widget is reconfigured…
        #expect(backend.makeCount == 0)                   // …not rebuilt
    }
}

@MainActor
private struct ToggleImageView: View {
    @State var alt = false
    var body: some View {
        VStack {
            Image(systemName: alt ? "b" : "a")
            Button("toggle") { alt.toggle() }
        }
    }
}
