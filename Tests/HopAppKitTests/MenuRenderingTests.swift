// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(AppKit)
import Testing
import AppKit
@testable import HopAppKit
import HopUI

/// Exercises the REAL AppKit drop-down construction (NSPopUpButton / NSMenu) headlessly — these widgets
/// build without a window or running app, so this verifies the native menu/picker mapping directly even
/// when no display is available.
@MainActor @Suite struct MenuRenderingTests {

    @Test func testActionMenuBuildsPullDownPopupWithSeparatorAndSubmenu() throws {
        let toolkit = AppKitToolkit()
        let handle = toolkit.makeNativeWidget(WidgetKey("menu"))
        var fired = ""
        toolkit.configureMenu(handle, MenuContent(label: "Actions", entries: [
            .button(title: "New", action: { fired = "New" }),
            .separator,
            .button(title: "Save", action: { fired = "Save" }),
            .submenu(title: "Export", entries: [.button(title: "PDF", action: {})]),
        ]))

        let popup = handle.view as! NSPopUpButton
        #expect(popup.pullsDown)
        // Item 0 is the always-shown label; then New, a separator, Save, and the Export submenu.
        #expect(popup.numberOfItems == 5)
        #expect(popup.item(at: 0)?.title == "Actions")
        #expect(popup.item(at: 1)?.title == "New")
        #expect(popup.item(at: 2)?.isSeparatorItem == true)
        #expect(popup.item(at: 3)?.title == "Save")
        #expect(popup.item(at: 4)?.submenu != nil)
        #expect(popup.item(at: 4)?.submenu?.numberOfItems == 1)

        // Invoking an item's target/action runs its Swift closure.
        let saveItem = popup.item(at: 3)!
        _ = (saveItem.target as? ActionTrampoline)?.fire()
        #expect(fired == "Save")
    }

    @Test func testPickerPopulatesOptionsSelectsAndReportsChanges() throws {
        let toolkit = AppKitToolkit()
        let handle = toolkit.makeNativeWidget(WidgetKey("picker"))
        var picked = -1
        toolkit.configurePicker(handle, PickerSpec(title: "Number", options: ["One", "Two", "Three"],
                                                   selectedIndex: 2, onSelect: { picked = $0 }))

        let popup = handle.view as! NSPopUpButton
        #expect(!popup.pullsDown)
        #expect(popup.itemTitles == ["One", "Two", "Three"])
        #expect(popup.indexOfSelectedItem == 2)

        // Simulate the user choosing the first item: select it and fire the target/action.
        popup.selectItem(at: 0)
        handle.pickerTarget?.changed(popup)
        #expect(picked == 0)
    }
}
#endif
