// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// The app-structure layer, mirroring SwiftUI's `App` / `Scene` / `WindowGroup` / `Window` so the
/// same `@main` app definition compiles against either HopUI or Apple's SwiftUI.
///
/// HopUI's runtime enumerates an app's scenes via the internal `_windows()` hook: the first
/// `WindowGroup` becomes the primary window, and each `Window(_:id:)` is registered so
/// `@Environment(\.openWindow)`'s `openWindow(id:)` can present it on demand (see `runApp`).

/// A part of an app's user interface with a life cycle managed by the system. Mirrors SwiftUI's
/// `Scene`. The `_windows()` requirement is HopUI's internal seam for enumerating an app's windows.
@MainActor
public protocol Scene {
    /// The windows this scene contributes, in declaration order. Not part of SwiftUI's public API.
    func _windows() -> [_WindowDef]
    /// The app menu commands this scene contributes (via `.commands`). Internal seam; defaults to none.
    func _commands() -> [MenuSpec]
}

extension Scene {
    public func _commands() -> [MenuSpec] { [] }
}

/// A toolkit-agnostic description of one window: its identity (`nil` for the primary `WindowGroup`),
/// its title, and a factory for its root content. Public only so the cross-module runtime can read it.
public struct _WindowDef {
    public let id: String?
    public let title: String
    public let content: @MainActor () -> any View

    init(id: String?, title: String, content: @escaping @MainActor () -> any View) {
        self.id = id
        self.title = title
        self.content = content
    }
}

/// A scene presenting a group of identically-structured windows. Mirrors SwiftUI's `WindowGroup`;
/// HopUI treats it as the app's primary window.
public struct WindowGroup<Content: View>: Scene {
    let title: String
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.title = ""
        self.content = content()
    }

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public func _windows() -> [_WindowDef] {
        let content = self.content
        return [_WindowDef(id: nil, title: title, content: { content })]
    }
}

/// A scene presenting a single, uniquely-identified window. Mirrors SwiftUI's `Window`; HopUI opens
/// it on demand via `openWindow(id:)`.
public struct Window<Content: View>: Scene {
    let title: String
    let id: String
    let content: Content

    public init(_ title: String, id: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.id = id
        self.content = content()
    }

    public func _windows() -> [_WindowDef] {
        let content = self.content
        let title = self.title
        let id = self.id
        return [_WindowDef(id: id, title: title, content: { content })]
    }
}

/// Combines several sibling scenes produced by ``SceneBuilder``.
public struct _TupleScene: Scene {
    let scenes: [any Scene]
    init(_ scenes: [any Scene]) { self.scenes = scenes }
    public func _windows() -> [_WindowDef] { scenes.flatMap { $0._windows() } }
    public func _commands() -> [MenuSpec] { scenes.flatMap { $0._commands() } }
}

/// A scene that carries app menu commands (from `.commands`) over a base scene. Mirrors how SwiftUI's
/// `.commands` modifies a scene.
public struct _CommandsScene<Base: Scene>: Scene {
    let base: Base
    let commands: [MenuSpec]
    public func _windows() -> [_WindowDef] { base._windows() }
    public func _commands() -> [MenuSpec] { base._commands() + commands }
}

extension Scene {
    /// Adds app menu commands to the menu bar. Mirrors SwiftUI's `.commands(content:)`.
    public func commands(@CommandsBuilder _ content: () -> some Commands) -> some Scene {
        _CommandsScene(base: self, commands: content()._menuSpecs())
    }
}

/// A group of app menu commands, mirroring SwiftUI's `Commands`.
@MainActor
public protocol Commands {
    func _menuSpecs() -> [MenuSpec]
}

/// A top-level command menu added to the menu bar, mirroring SwiftUI's `CommandMenu`. Its content is
/// a set of `Button`s (and separators); their actions become menu item actions.
public struct CommandMenu<Content: View>: Commands {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public func _menuSpecs() -> [MenuSpec] {
        var items: [MenuItemSpec] = []
        for node in evaluateResolved(content, RenderContext(path: [.index(0)])) where node.component.widgetKey == .button {
            items.append(.button(node.effectivePatch.title ?? "", action: node.effectiveAction ?? {}))
        }
        return [MenuSpec(title, items: items)]
    }
}

/// Combines command groups for `.commands`. Mirrors SwiftUI's `CommandsBuilder`.
@resultBuilder
@MainActor
public enum CommandsBuilder {
    public static func buildBlock<C: Commands>(_ content: C) -> C { content }

    public static func buildBlock<each C: Commands>(_ content: repeat each C) -> _TupleCommands {
        var parts: [any Commands] = []
        repeat parts.append(each content)
        return _TupleCommands(parts)
    }
}

public struct _TupleCommands: Commands {
    let parts: [any Commands]
    init(_ parts: [any Commands]) { self.parts = parts }
    public func _menuSpecs() -> [MenuSpec] { parts.flatMap { $0._menuSpecs() } }
}

/// Result builder that assembles an app's `body` from one or more scenes. Mirrors SwiftUI's
/// `SceneBuilder`.
@resultBuilder
@MainActor
public enum SceneBuilder {
    public static func buildBlock<Content: Scene>(_ content: Content) -> Content { content }

    public static func buildBlock<each Content: Scene>(_ content: repeat each Content) -> _TupleScene {
        var scenes: [any Scene] = []
        repeat scenes.append(each content)
        return _TupleScene(scenes)
    }
}

/// The entry point of a HopUI app. Mirrors SwiftUI's `App`. A HopUI executable selects its toolkit
/// in `main.swift` and calls `runApp(MyApp(), toolkit:)`; the native (SwiftUI) build uses `@main`
/// and Apple's own `App.main()`.
@MainActor
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
    init()
}
