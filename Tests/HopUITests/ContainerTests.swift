// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

@MainActor private struct TabHost: View {
    var body: some View {
        TabView {
            Text("Page One").tabItem { Text("One") }
            Text("Page Two").tabItem { Label("Two", systemImage: "2.circle") }
        }
    }
}

@MainActor @Suite struct ContainerTests {
    @Test func testGroupBoxWrapsTitledContentInACard() {
        let backend = MockBackend()
        runHopApp(GroupBox("Appearance") { Text("Inside the box") }, backend: backend, title: "test")
        #expect(backend.widgets.contains { $0.kind == .groupBox })
        #expect(backend.liveLabels().contains("Appearance"))
        #expect(backend.liveLabels().contains("Inside the box"))
    }

    @Test func testSectionHasHeaderAboveCard() {
        let backend = MockBackend()
        runHopApp(Section("General") { Text("A row") }, backend: backend, title: "test")
        #expect(backend.widgets.contains { $0.kind == .groupBox })
        #expect(backend.liveLabels().contains("General"))
        #expect(backend.liveLabels().contains("A row"))
    }

    @Test func testFormScrollsAndGroupsSections() {
        let backend = MockBackend()
        runHopApp(Form { Section("S") { Text("field") } }, backend: backend, title: "test")
        #expect(backend.widgets.contains { $0.kind == .scroll })
        #expect(backend.widgets.contains { $0.kind == .groupBox })
        #expect(backend.liveLabels().contains("field"))
    }

    @Test func testTabViewBuildsNativeTabsAndSwitches() throws {
        let backend = MockBackend()
        runHopApp(TabHost(), backend: backend, title: "test")

        // A native .tabView carries the tab titles (from .tabItem; a Label's text is extracted) + selection.
        let tabView = try #require(backend.widgets.first { $0.kind == .tabView })
        let spec = try #require(tabView.tabSpec)
        #expect(spec.titles == ["One", "Two"])
        #expect(spec.selectedIndex == 0)

        // Both pages stay mounted (the native widget shows the selected one), unlike the old faked version.
        #expect(backend.liveLabels().contains("Page One"))
        #expect(backend.liveLabels().contains("Page Two"))

        // The native widget reports a user tab switch; selection flows back and re-renders.
        backend.clearOps()
        spec.onSelect(1)
        backend.drainMainThread()
        let updated = try #require((backend.widgets.first { $0.kind == .tabView })?.tabSpec)
        #expect(updated.selectedIndex == 1)
        #expect(backend.makeCount == 0)  // pages were not rebuilt, just re-selected
    }
}
