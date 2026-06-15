// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Observation

/// An environment system mirroring SwiftUI's `@Environment` / `EnvironmentValues`. It vends the
/// `openWindow` action by key path and `@Observable` objects by type. The environment is a single
/// "ambient" value that the evaluator brackets as it descends into `.environment(_:)` subtrees (set
/// on enter, restored on exit), so an object injected on an ancestor is visible to its descendants
/// and to nobody else — matching SwiftUI's scoping while the full per-node environment tree remains a
/// later refinement. (The whole UI runs synchronously on the main actor, which makes the ambient
/// approach sound.)

/// An action that presents the window registered for a given identifier. Mirrors SwiftUI's
/// `OpenWindowAction`; invoked as `openWindow(id: "about")`.
///
/// The initializer is left non-isolated so the default `EnvironmentValues.openWindow` value can be
/// constructed without main-actor isolation; only `callAsFunction` (which runs the handler) is
/// main-actor isolated.
public struct OpenWindowAction {
    let handler: @MainActor (String) -> Void

    init(handler: @escaping @MainActor (String) -> Void) { self.handler = handler }

    @MainActor public func callAsFunction(id: String) { handler(id) }
}

/// A collection of environment values. Mirrors SwiftUI's `EnvironmentValues`: it carries key-path
/// values (like `openWindow`) and `@Observable` reference objects keyed by their type.
public struct EnvironmentValues {
    public init() {}

    /// The action that opens a registered secondary window. The runtime installs a working action in
    /// `runApp`; the default is a no-op so reads outside a running app are harmless.
    public var openWindow = OpenWindowAction(handler: { _ in })

    /// The enclosing `NavigationStack`'s push action, installed by the stack while it evaluates its
    /// content so that a `NavigationLink` inside can append a value to the stack's path. `nil` outside
    /// a navigation stack.
    public var navigationPush: ((AnyHashable) -> Void)?

    /// Inherited text styling, set by `.font` / `.fontWeight` / `.foregroundStyle` and read by `Text`.
    public var font: Font?
    public var fontWeightOverride: Font.Weight?
    public var foregroundColor: Color?

    /// The light/dark appearance, settable via `.environment(\.colorScheme, _)` and readable via
    /// `@Environment(\.colorScheme)`. Mirrors SwiftUI's `\.colorScheme`.
    public var colorScheme: ColorScheme = .light

    /// Objects injected via `.environment(_:)`, keyed by their dynamic type's identifier.
    private var objects: [ObjectIdentifier: Any] = [:]

    public mutating func setObject<T>(_ object: T) {
        objects[ObjectIdentifier(T.self)] = object
    }

    public func object<T>(_ type: T.Type) -> T? {
        objects[ObjectIdentifier(type)] as? T
    }
}

/// The ambient environment for the current point in the view walk. The evaluator brackets this as it
/// enters and leaves `.environment(_:)` subtrees.
@MainActor
enum EnvironmentStore {
    static var current = EnvironmentValues()
}

/// Reads a value from the app's environment. Mirrors SwiftUI's `@Environment`, supporting both the
/// key-path form (`@Environment(\.openWindow)`) and the object-type form
/// (`@Environment(SomeObservable.self)`).
///
/// The value is resolved from the ambient environment on first read and cached in a shared box. Views
/// read their `@Environment` during `body` evaluation — when the ambient environment is correctly
/// bracketed for that subtree — so the cached value is then available to closures that capture the
/// view (e.g. a button action that reads or mutates it when tapped, long after evaluation, by which
/// point the ambient environment has been restored). A value not yet cached falls back to the current
/// ambient environment, which is what makes process-wide values like `openWindow` work from actions.
@propertyWrapper
@MainActor
public struct Environment<Value> {
    private enum Source {
        case keyPath(KeyPath<EnvironmentValues, Value>)
        case objectType
    }
    private let source: Source
    // A reference shared across struct copies (including the copy a closure captures), so the value
    // cached during body evaluation is visible to the view's captured closures. Deliberately
    // non-generic (`Any`-typed) to avoid instantiating a generic box metadata over `@Observable`
    // model types, which can trip a Swift runtime generic-metadata prespecialization crash.
    private let box = EnvironmentBox()

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) { source = .keyPath(keyPath) }

    /// Reads an `@Observable` object of the given type from the environment. Mirrors SwiftUI's
    /// `@Environment(T.self)`.
    public init(_ objectType: Value.Type) { source = .objectType }

    public var wrappedValue: Value {
        if let cached = box.value as? Value { return cached }
        let value = resolved(from: EnvironmentStore.current)
        box.value = value
        return value
    }

    private func resolved(from environment: EnvironmentValues) -> Value {
        switch source {
        case .keyPath(let keyPath):
            return environment[keyPath: keyPath]
        case .objectType:
            guard let object = environment.object(Value.self) else {
                fatalError("No \(Value.self) in the environment — inject one with .environment(_:)")
            }
            return object
        }
    }
}

/// A mutable, non-generic reference cell holding the environment value resolved for a particular
/// `@Environment` (stored as `Any` to avoid generic-metadata instantiation over the value type).
final class EnvironmentBox {
    var value: Any?
}

/// Injects an `@Observable` object into the environment for a view's descendants. Mirrors SwiftUI's
/// `.environment(_:)`; read it back with `@Environment(T.self)`.
public struct _EnvironmentWritingView<Content: View>: View, AnyEnvironmentWriter {
    let content: Content
    let write: (inout EnvironmentValues) -> Void

    public typealias Body = Never
    public var body: Never { fatalError("_EnvironmentWritingView has no body") }

    var environmentContent: any View { content }
    func writeEnvironment(_ environment: inout EnvironmentValues) { write(&environment) }
}

/// Internal protocol letting the evaluator apply a view's environment additions to the subtree.
@MainActor
protocol AnyEnvironmentWriter {
    var environmentContent: any View { get }
    func writeEnvironment(_ environment: inout EnvironmentValues)
}

extension View {
    /// Places an observable object into the environment, readable by descendants via
    /// `@Environment(T.self)`. Mirrors SwiftUI's `.environment(_:)`.
    public func environment<T>(_ object: T?) -> some View where T: AnyObject, T: Observable {
        _EnvironmentWritingView(content: self) { environment in
            if let object { environment.setObject(object) }
        }
    }

    /// Sets an environment value by key path for this view's descendants. Mirrors SwiftUI's
    /// `.environment(_:_:)` — e.g. `.environment(\.colorScheme, .light)`.
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> some View {
        _EnvironmentWritingView(content: self) { $0[keyPath: keyPath] = value }
    }
}
