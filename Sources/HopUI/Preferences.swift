// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Preference collection: after a render pass produces the (assembled) node tree, a cheap pre-order walk
// gathers the preferences that views attached to their nodes (`.toolbar`, `.preferredColorScheme`,
// `.navigationTitle`, `.navigationDestination`). This replaces the old global side-effect collectors,
// which silently lost a memoized (un-re-run) subtree's contributions — the attached data, by contrast,
// lives in cached subtrees' nodes and so survives memoization. (See
// `project_hopui_finegrained_reactivity`.)

/// Collect window-level preferences from the whole tree: toolbar items (concatenated in pre-order) and
/// the preferred color scheme (outermost wins — the first encountered in pre-order).
@MainActor
func collectWindowPreferences(_ root: RenderNode) -> (toolbar: [ToolbarItemSpec], colorScheme: ColorScheme?) {
    var toolbar: [ToolbarItemSpec] = []
    var colorScheme: ColorScheme?
    func walk(_ node: RenderNode) {
        if let prefs = node.preferences {
            if let items = prefs.toolbar { toolbar += items }
            if colorScheme == nil, let scheme = prefs.preferredColorScheme { colorScheme = scheme }
        }
        for child in node.children { walk(child) }
    }
    walk(root)
    return (toolbar, colorScheme)
}

/// Collect the navigation preferences contributed by a subtree (an enclosing `NavigationStack`'s
/// content): the navigation title (outermost wins) and the registered `.navigationDestination` builders.
@MainActor
func collectNavigationPreferences(_ nodes: [RenderNode])
    -> (title: String?, destinations: [ObjectIdentifier: (AnyHashable) -> any View]) {
    var title: String?
    var destinations: [ObjectIdentifier: (AnyHashable) -> any View] = [:]
    func walk(_ node: RenderNode) {
        if let prefs = node.preferences {
            if title == nil, let t = prefs.navigationTitle { title = t }
            if let dests = prefs.navigationDestinations {
                destinations.merge(dests) { _, new in new }
            }
        }
        for child in node.children { walk(child) }
    }
    for node in nodes { walk(node) }
    return (title, destinations)
}
