// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// A standard editing command. Toolkits map these to the platform's native edit action so they
/// operate on the focused control (e.g. the text field) — AppKit's `cut:`/`copy:`/`paste:`
/// first-responder selectors, GTK's `clipboard.*` widget actions, Qt's `QLineEdit` slots.
public enum StandardCommand: Sendable {
    case cut, copy, paste, undo, redo, selectAll
}

/// One item in an app menu.
public struct MenuItemSpec {
    public enum Kind {
        case button(title: String, action: @MainActor () -> Void)
        case command(title: String, command: StandardCommand)
        case separator
    }
    public let kind: Kind

    public static var separator: MenuItemSpec { MenuItemSpec(kind: .separator) }
    public static func command(_ title: String, _ command: StandardCommand) -> MenuItemSpec {
        MenuItemSpec(kind: .command(title: title, command: command))
    }
    public static func button(_ title: String, action: @escaping @MainActor () -> Void) -> MenuItemSpec {
        MenuItemSpec(kind: .button(title: title, action: action))
    }
}

/// A top-level app menu (File, Edit, View, …) with its items.
public struct MenuSpec {
    public let title: String
    public let items: [MenuItemSpec]
    public init(_ title: String, items: [MenuItemSpec]) {
        self.title = title
        self.items = items
    }
}

/// The standard menu bar HopUI installs automatically. This is the shared-code handling for a
/// genuine platform difference: SwiftUI (and the macOS app environment) provide the standard
/// File/Edit/View/Window/Help menus — with working Cut/Copy/Paste — for free, while the GTK4 and Qt
/// toolkits do not. HopUI installs an equivalent standard menu bar on every toolkit so apps don't
/// have to, and the surface stays free of a non-SwiftUI `.commands` modifier.
@MainActor
func hopStandardMenus() -> [MenuSpec] {
    [
        MenuSpec("File", items: []),
        MenuSpec("Edit", items: [
            .command("Cut", .cut),
            .command("Copy", .copy),
            .command("Paste", .paste),
            .separator,
            .command("Select All", .selectAll),
        ]),
        MenuSpec("View", items: []),
        MenuSpec("Window", items: []),
        MenuSpec("Help", items: []),
    ]
}
