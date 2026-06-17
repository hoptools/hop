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
        let toolkit = MockToolkit()
        runHopApp(GroupBox("Appearance") { Text("Inside the box") }, toolkit: toolkit, title: "test")
        #expect(toolkit.widgets.contains { $0.kind == "groupBox" })
        #expect(toolkit.liveLabels().contains("Appearance"))
        #expect(toolkit.liveLabels().contains("Inside the box"))
    }

    @Test func testSectionHasHeaderAboveCard() {
        let toolkit = MockToolkit()
        runHopApp(Section("General") { Text("A row") }, toolkit: toolkit, title: "test")
        #expect(toolkit.widgets.contains { $0.kind == "groupBox" })
        #expect(toolkit.liveLabels().contains("General"))
        #expect(toolkit.liveLabels().contains("A row"))
    }

    @Test func testFormScrollsAndGroupsSections() {
        let toolkit = MockToolkit()
        runHopApp(Form { Section("S") { Text("field") } }, toolkit: toolkit, title: "test")
        #expect(toolkit.widgets.contains { $0.kind == "scroll" })
        #expect(toolkit.widgets.contains { $0.kind == "groupBox" })
        #expect(toolkit.liveLabels().contains("field"))
    }

    @Test func testTabViewBuildsNativeTabsAndSwitches() throws {
        let toolkit = MockToolkit()
        runHopApp(TabHost(), toolkit: toolkit, title: "test")

        // A native .tabView carries the tab titles (from .tabItem; a Label's text is extracted) + selection.
        let tabView = try #require(toolkit.widgets.first { $0.kind == "tabView" })
        let spec = try #require(tabView.tabSpec)
        #expect(spec.titles == ["One", "Two"])
        #expect(spec.selectedIndex == 0)

        // Both pages stay mounted (the native widget shows the selected one), unlike the old faked version.
        #expect(toolkit.liveLabels().contains("Page One"))
        #expect(toolkit.liveLabels().contains("Page Two"))

        // The native widget reports a user tab switch; selection flows back and re-renders.
        toolkit.clearOps()
        spec.onSelect(1)
        toolkit.drainMainThread()
        let updated = try #require((toolkit.widgets.first { $0.kind == "tabView" })?.tabSpec)
        #expect(updated.selectedIndex == 1)
        #expect(toolkit.makeCount == 0)  // pages were not rebuilt, just re-selected
    }
}
