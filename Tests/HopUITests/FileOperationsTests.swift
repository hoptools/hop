// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import HopUI

@MainActor private final class Captured { var value = "none" }

@MainActor private struct ImporterHost: View {
    @State var present = false
    let captured: Captured
    var body: some View {
        Button("Open") { present = true }
            .fileImporter(isPresented: $present, allowedContentTypes: [.plainText, .json]) { result in
                if case .success(let urls) = result { captured.value = urls.first?.lastPathComponent ?? "none" }
            }
    }
}

@MainActor private struct ExporterHost: View {
    @State var present = false
    var body: some View {
        Button("Save") { present = true }
            .fileExporter(isPresented: $present, document: Data("hop".utf8),
                          contentType: .plainText, defaultFilename: "out.txt") { _ in }
    }
}

@MainActor @Suite struct FileOperationsTests {
    @Test func testImporterPresentsOnTrueAndDismisses() throws {
        let toolkit = MockToolkit()
        let captured = Captured()
        runHopApp(ImporterHost(captured: captured), toolkit: toolkit, title: "test")

        // The modifier attaches the spec to the wrapped (button) node; initially not presented.
        let initial = try #require(toolkit.widgets.first { $0.fileImporter != nil })
        #expect(initial.fileImporter?.isPresented == false)
        #expect(initial.fileImporter?.allowsMultipleSelection == false)
        #expect(initial.fileImporter?.allowedContentTypes.count == 2)

        // Flip isPresented via the button; the toolkit is asked to present.
        toolkit.clearOps()
        initial.action?()
        toolkit.drainMainThread()
        #expect(toolkit.ops.contains("fileImporter"))
        let spec = try #require(toolkit.widgets.first { $0.fileImporter != nil }?.fileImporter)
        #expect(spec.isPresented == true)

        // Simulate the panel returning a file: onCompletion fires, setPresented(false) dismisses.
        spec.onCompletion(.success([URL(fileURLWithPath: "/tmp/demo.txt")]))
        spec.setPresented(false)
        toolkit.drainMainThread()
        #expect(captured.value == "demo.txt")
        #expect(toolkit.widgets.first { $0.fileImporter != nil }?.fileImporter?.isPresented == false)
    }

    @Test func testExporterCarriesDataAndDefaultName() throws {
        let toolkit = MockToolkit()
        runHopApp(ExporterHost(), toolkit: toolkit, title: "test")
        let button = try #require(toolkit.widgets.first { $0.fileExporter != nil })
        toolkit.clearOps()
        button.action?()
        toolkit.drainMainThread()
        #expect(toolkit.ops.contains("fileExporter"))
        let spec = try #require(toolkit.widgets.first { $0.fileExporter != nil }?.fileExporter)
        #expect(spec.isPresented == true)
        #expect(spec.defaultFilename == "out.txt")
        #expect(spec.data == Data("hop".utf8))
    }
}
