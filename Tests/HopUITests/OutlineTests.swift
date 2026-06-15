// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

/// A recursive category model for exercising `OutlineGroup`.
private struct OutlineCategory: Identifiable, Hashable {
    let id: String
    let title: String
    var children: [OutlineCategory]? = nil
}

private let outlineRoots: [OutlineCategory] = [
    OutlineCategory(id: "controls", title: "Controls", children: [
        OutlineCategory(id: "slider", title: "Slider"),
        OutlineCategory(id: "button", title: "Button"),
    ]),
    OutlineCategory(id: "containers", title: "Containers", children: [
        OutlineCategory(id: "stacks", title: "Stacks"),
    ]),
]

@MainActor
private struct OutlineSidebarView: View {
    @State var selection: String? = nil
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                OutlineGroup(outlineRoots, children: \.children) { Text($0.title) }
            }
        } detail: {
            Text(selection.map { "Selected \($0)" } ?? "No selection")
        }
    }
}

@MainActor @Suite struct OutlineTests {
    @Test func testOutlineBuildsSidebarTreeAndSelectionBinds() throws {
        let backend = MockBackend()
        runHopApp(OutlineSidebarView(), backend: backend, title: "test")

        // In a NavigationSplitView's leading column, the OutlineGroup renders as a source-list tree.
        let outline = try #require(backend.widgets.first { $0.kind == .sidebarOutline })
        let spec = try #require(outline.outline)
        #expect(spec.roots.count == 2)
        #expect(spec.roots[0].title == "Controls")
        #expect(spec.roots[0].children.map(\.title) == ["Slider", "Button"])
        #expect(spec.roots[1].children.map(\.title) == ["Stacks"])
        #expect(spec.selectedID == nil)
        #expect(backend.liveLabels().contains("No selection"))

        // Selecting a leaf flows back through the binding into @State, reflected in the detail.
        backend.clearOps()
        outline.outline?.onSelect(AnyHashable("slider"))
        backend.drainMainThread()
        #expect(backend.liveLabels().contains("Selected slider"))
        #expect(backend.makeCount == 0)  // a selection change rebuilds no widgets

        // After the re-render the outline spec carries the selection back down.
        let updated = try #require((backend.widgets.first { $0.kind == .sidebarOutline })?.outline)
        #expect(updated.selectedID == AnyHashable("slider"))
    }

    @Test func testOutlineFlattenAndStructureSignature() {
        let spec = OutlineSpec(roots: outlineRoots.map(Self.node))
        // Pre-order flattening with depth: Controls(0) Slider(1) Button(1) Containers(0) Stacks(1).
        let flat = spec.flattened()
        #expect(flat.map(\.node.title) == ["Controls", "Slider", "Button", "Containers", "Stacks"])
        #expect(flat.map(\.depth) == [0, 1, 1, 0, 1])
        // The signature changes with the structure but not with selection.
        var withSelection = spec
        withSelection.selectedID = AnyHashable("slider")
        #expect(spec.structureSignature == withSelection.structureSignature)
    }

    private static func node(_ category: OutlineCategory) -> OutlineSpec.Node {
        OutlineSpec.Node(id: AnyHashable(category.id), title: category.title,
                         children: (category.children ?? []).map(node))
    }
}

@MainActor
private struct DisclosureBoundView: View {
    @State var expanded = false
    var body: some View {
        VStack {
            DisclosureGroup("More", isExpanded: $expanded) {
                Text("Hidden detail")
            }
        }
    }
}

@MainActor @Suite struct DisclosureGroupTests {
    @Test func testDisclosureGroupTogglesContent() throws {
        let backend = MockBackend()
        runHopApp(DisclosureBoundView(), backend: backend, title: "test")

        let header = try #require(backend.widgets.first { $0.kind == .button })
        #expect(header.title == "▸  More")
        #expect(!backend.liveLabels().contains("Hidden detail"))  // collapsed: content not mounted

        // Tapping the header toggles the bound expansion state and reveals the content.
        backend.clearOps()
        header.action?()
        backend.drainMainThread()
        #expect(backend.liveLabels().contains("Hidden detail"))
        let expandedHeader = try #require(backend.liveLabels().first { $0.hasSuffix("More") })
        #expect(expandedHeader == "▾  More")
    }
}
