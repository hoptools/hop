// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import HopGraph
import Observation
import Foundation  // ProcessInfo (HOP_WINDOW_SIZE)

/// The primary window's initial size requested via `HOP_WINDOW_SIZE=WIDTHxHEIGHT` (e.g. `1280x800`), or
/// nil when unset/malformed. Used to make CI/marketing screenshots a uniform size across every backend;
/// each toolkit's `run` honors it when creating its primary window.
public func hopRequestedWindowSize() -> (width: Double, height: Double)? {
    guard let raw = ProcessInfo.processInfo.environment["HOP_WINDOW_SIZE"] else { return nil }
    let parts = raw.lowercased().split(separator: "x")
    guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
    return (w, h)
}

/// Boots a HopUI ``App``: enumerates its scenes, registers the `openWindow` action, and runs the
/// primary `WindowGroup` window through the given toolkit's main loop.
///
/// The first scene without an id (the `WindowGroup`) is the primary, fully-reactive window. Each
/// `Window(_:id:)` scene is registered so `@Environment(\.openWindow)`'s `openWindow(id:)` can
/// present it on demand. This is the entry point HopUI executables use; the native SwiftUI build
/// uses `@main` and Apple's own `App.main()` instead.
public func runApp<A: App, Toolkit: AppToolkit>(_ app: A, toolkit: Toolkit) {
    let body = app.body
    let windows = body._windows()
    let appCommands = body._commands()  // app-provided menu commands (Scene `.commands`)

    // Register the id'd windows (the `Window(_:id:)` scenes) for on-demand presentation.
    var registry: [String: _WindowDef] = [:]
    for window in windows {
        if let id = window.id, registry[id] == nil { registry[id] = window }
    }

    // Seed the base environment with the openWindow action before the (blocking) main loop starts.
    var baseEnvironment = EnvironmentValues()
    baseEnvironment.openWindow = OpenWindowAction { id in
        guard let def = registry[id] else { return }
        openSecondaryWindow(def, toolkit: toolkit)
    }

    // The primary window is the first `WindowGroup` (id == nil); fall back to the first scene.
    guard let primary = windows.first(where: { $0.id == nil }) ?? windows.first else { return }
    runRootView(primary.content, title: primary.title, appCommands: appCommands, toolkit: toolkit,
                baseEnvironment: baseEnvironment)
}

/// Boots a HopUI app from a single root view (no scene graph). Kept for tests and simple embedding;
/// app code uses ``runApp(_:toolkit:)`` with an ``App``.
public func runHopApp<Root: View, Toolkit: AppToolkit>(_ root: Root, toolkit: Toolkit, title: String) {
    runRootView({ root }, title: title, appCommands: [], toolkit: toolkit)
}

/// The menu bar: HopUI's standard menus with any app-provided command menus inserted after "View".
@MainActor
func mergedMenus(_ appCommands: [MenuSpec]) -> [MenuSpec] {
    var menus = hopStandardMenus()
    guard !appCommands.isEmpty else { return menus }
    menus.insert(contentsOf: appCommands, at: Swift.min(3, menus.count))
    return menus
}

/// Runs one fully-reactive root view as the toolkit's primary window: wires it into the attribute
/// graph, mounts it, installs the toolbar + standard menus, and runs the platform main loop.
///
/// The render tree is produced by a **retained, identity-keyed view graph** (``ViewGraph``): each
/// composite view's `body` is its own memoized graph rule, the environment flows down as a graph
/// attribute, and preferences flow up as data on the nodes. A `@State`/`@Observable` write invalidates
/// only the composite(s) that read it and schedules a flush; the flush re-pulls the tree (re-running
/// just the changed composites' bodies) and the reconciler applies the minimal native mutations.
/// (See `project_hopui_finegrained_reactivity`.)
func runRootView<Toolkit: AppToolkit>(_ makeRoot: @escaping @MainActor () -> any View,
                                      title: String, appCommands: [MenuSpec] = [], toolkit: Toolkit,
                                      baseEnvironment: EnvironmentValues = EnvironmentValues()) {
    let graph = Graph()
    GraphContext.current = graph
    GraphContext.resetForNewApp()  // clear any prior run's pending-flush flag so this app's flushes aren't suppressed
    IdentitySourceStore.reset()  // fresh layout-feedback sources for this run's graph
    ScrollContextStore.reset()
    SidebarColumnContext.reset()

    // The retained view graph: per-composite memoized bodies + identity-keyed @State + the environment
    // chain. Held for the app's lifetime.
    let viewGraph = ViewGraph(graph: graph)
    GraphContext.viewGraph = viewGraph
    graph.setValue(baseEnvironment, for: viewGraph.baseEnvironment)  // seed openWindow etc.

    // Held for the app's lifetime so its identity is stable across re-evaluations.
    let rootView = makeRoot()
    let rootContext = RenderContext(path: [.index(0)])

    // One render pass: route the root through the registry under the base environment, returning the
    // assembled tree. Only composites whose inputs changed re-run their bodies; the rest are memoized.
    let renderPass: @MainActor () -> RenderNode = {
        let savedEnv = EnvironmentStore.currentAttr
        EnvironmentStore.currentAttr = viewGraph.baseEnvironment
        defer { EnvironmentStore.currentAttr = savedEnv }
        // Evaluate the root (emitting composite references), then resolve — re-running only the bodies
        // that were invalidated since the last pass.
        let resolved = resolveRenderTree(evaluate(rootView, rootContext), graph)
        return resolved.first ?? RenderNode(id: rootContext.id, component: ContainerComponent.vstack())
    }

    let reconciler = Reconciler(toolkit: toolkit)

    // Run the framework-owned layout engine over the current tree at the window's content size.
    let relayout: @MainActor () -> Void = {
        reconciler.layout(in: CGRect(origin: .zero, size: toolkit.contentSize()))
    }

    // Apply window-level preferences (toolbar, color scheme) collected by walking the tree.
    let applyPreferences: @MainActor (RenderNode) -> Void = { root in
        let prefs = collectWindowPreferences(root)
        toolkit.setToolbar(prefs.toolbar)
        toolkit.setColorScheme(prefs.colorScheme)
    }

    GraphContext.flush = {
        guard graph.hasDirty else { return }
        graph.clearDirty()
        let root = renderPass()
        reconciler.update(root)
        applyPreferences(root)
        relayout()
    }

    // Flushes are coalesced onto the toolkit's main loop (see GraphContext.scheduleFlush): one
    // re-render per loop turn, after the current native event finishes. `@Observable` changes invalidate
    // the specific composite that read the property (no global root invalidation needed anymore).
    GraphContext.scheduleOnMain = { work in toolkit.scheduleOnMainThread(work) }
    GraphContext.invalidateRoot = { }

    toolkit.run(title: title) { container in
        let root = renderPass()
        reconciler.mount(root, into: container)
        applyPreferences(root)
        // HopUI's standard menu bar, plus any app-provided command menus (Scene `.commands`).
        toolkit.setMenu(mergedMenus(appCommands))
        // Own the geometry: lay out now, again after native composites settle, and on every resize.
        toolkit.setRelayoutHandler(relayout)
        relayout()
        toolkit.scheduleOnMainThread(relayout)
    }
}

/// Opens a secondary window (e.g. an About window) from a `Window(_:id:)` scene. Its content is
/// rendered once from a snapshot — secondary windows are static in this MVP, so they need no ongoing
/// reactivity. Full per-window `@State` graphs are a later refinement.
@MainActor
func openSecondaryWindow<Toolkit: AppToolkit>(_ def: _WindowDef, toolkit: Toolkit) {
    // Evaluate the content against a throwaway graph + view graph so any @State initializes; restore the
    // primary window's graph afterward so its flushes keep using it.
    let savedGraph = GraphContext.current
    let savedViewGraph = GraphContext.viewGraph
    let savedEnv = EnvironmentStore.currentAttr
    let graph = Graph()
    let viewGraph = ViewGraph(graph: graph)
    GraphContext.current = graph
    GraphContext.viewGraph = viewGraph
    EnvironmentStore.currentAttr = viewGraph.baseEnvironment
    defer {
        GraphContext.current = savedGraph
        GraphContext.viewGraph = savedViewGraph
        EnvironmentStore.currentAttr = savedEnv
    }

    let nodes = evaluateResolved(def.content(), RenderContext(path: [.index(0)]))
    let root = nodes.first ?? RenderNode(id: "0", component: ContainerComponent.vstack())

    toolkit.openWindow(title: def.title) { container in
        let reconciler = Reconciler(toolkit: toolkit)
        reconciler.mount(root, into: container)
    }
}
