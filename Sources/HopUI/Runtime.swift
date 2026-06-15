// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import HopGraph
import Observation

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

    // Install the openWindow environment action before the (blocking) main loop starts.
    EnvironmentStore.current.openWindow = OpenWindowAction { id in
        guard let def = registry[id] else { return }
        openSecondaryWindow(def, toolkit: toolkit)
    }

    // The primary window is the first `WindowGroup` (id == nil); fall back to the first scene.
    guard let primary = windows.first(where: { $0.id == nil }) ?? windows.first else { return }
    runRootView(primary.content, title: primary.title, appCommands: appCommands, toolkit: toolkit)
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
/// The whole render tree is produced by a single root rule attribute that reads `@State` as it
/// walks the view tree. A `@State` write invalidates that rule and schedules a flush, which
/// re-pulls the tree and lets the reconciler apply the minimal native mutations. (Fine-grained
/// per-body attributes are a later refinement; the reconciler already minimizes widget churn.)
func runRootView<Toolkit: AppToolkit>(_ makeRoot: @escaping @MainActor () -> any View,
                                      title: String, appCommands: [MenuSpec] = [], toolkit: Toolkit) {
    let graph = Graph()
    GraphContext.current = graph
    GraphContext.resetForNewApp()  // clear any prior run's pending-flush flag so this app's flushes aren't suppressed
    IdentitySourceStore.reset()  // fresh layout-feedback sources for this run's graph
    ScrollContextStore.reset()
    SidebarColumnContext.reset()

    // Held for the app's lifetime so its @State boxes survive across re-evaluations.
    let rootView = makeRoot()

    // A graph source bumped whenever an observed @Observable property changes; the render rule reads
    // it so those changes invalidate (and re-pull) the tree, alongside @State.
    let observationTick = graph.makeSource(0)

    // HopGraph is isolation-agnostic, so its rule closures are nonisolated; the view evaluation
    // they drive is main-actor work. We always read the graph on the main actor, so asserting that
    // isolation here is sound.
    let renderRoot: Attribute<RenderResult> = graph.makeRule { _ in
        MainActor.assumeIsolated {
            _ = GraphContext.requireCurrent().read(observationTick)
            // Track @Observable reads made during evaluation; the first subsequent mutation of any
            // read property fires onChange, which schedules a deferred re-render (re-establishing
            // tracking on the next pass).
            return withObservationTracking {
                ToolbarCollector.reset()
                PreferredColorSchemeStore.current = nil
                let nodes = evaluate(rootView, RenderContext(path: [.index(0)]))
                let root = nodes.first ?? RenderNode(id: "0", kind: .vstack)
                return RenderResult(root: root, toolbar: ToolbarCollector.items,
                                    colorScheme: PreferredColorSchemeStore.current)
            } onChange: {
                MainActor.assumeIsolated { GraphContext.requestObservationFlush() }
            }
        }
    }

    let reconciler = Reconciler(toolkit: toolkit)

    // Run the framework-owned layout engine over the current tree at the window's content size.
    let relayout: @MainActor () -> Void = {
        reconciler.layout(in: CGRect(origin: .zero, size: toolkit.contentSize()))
    }

    GraphContext.flush = {
        guard graph.hasDirty else { return }
        graph.clearDirty()
        let result = graph.read(renderRoot)
        reconciler.update(result.root)
        toolkit.setToolbar(result.toolbar)
        toolkit.setColorScheme(result.colorScheme)
        relayout()
    }

    // All flushes are coalesced onto the toolkit's main loop (see GraphContext.scheduleFlush): one
    // re-render per loop turn, run after the current native event finishes. `invalidateRoot` bumps the
    // observation tick so the render rule re-evaluates — needed for `@Observable` (whose mutations
    // don't dirty a graph source) and harmless for `@State`.
    GraphContext.scheduleOnMain = { work in toolkit.scheduleOnMainThread(work) }
    GraphContext.invalidateRoot = {
        let graph = GraphContext.requireCurrent()
        graph.setValue(graph.read(observationTick) + 1, for: observationTick)
    }

    toolkit.run(title: title) { container in
        let result = graph.read(renderRoot)
        reconciler.mount(result.root, into: container)
        toolkit.setToolbar(result.toolbar)
        toolkit.setColorScheme(result.colorScheme)
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
    // Evaluate the content against a throwaway graph so any @State initializes; restore the primary
    // window's graph afterward so its flushes keep using it.
    let savedGraph = GraphContext.current
    GraphContext.current = Graph()
    defer { GraphContext.current = savedGraph }

    let nodes = evaluate(def.content(), RenderContext(path: [.index(0)]))
    let root = nodes.first ?? RenderNode(id: "0", kind: .vstack)

    toolkit.openWindow(title: def.title) { container in
        let reconciler = Reconciler(toolkit: toolkit)
        reconciler.mount(root, into: container)
    }
}

/// The output of one render pass: the view tree, the window-level toolbar items, and the preferred
/// color scheme (nil = follow the system).
struct RenderResult {
    let root: RenderNode
    let toolbar: [ToolbarItemSpec]
    let colorScheme: ColorScheme?
}
