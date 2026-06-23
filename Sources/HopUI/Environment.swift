// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import HopGraph
import Observation

/// An environment system mirroring SwiftUI's `@Environment` / `EnvironmentValues`. It vends the
/// `openWindow` action by key path and `@Observable` objects by type.
///
/// The environment flows DOWN the view tree as a **graph attribute** (see ``EnvironmentStore``): each
/// composite body rule brackets the attribute it received, and `.environment(_:)` derives a new
/// attribute for its subtree. Views read the environment *through the graph* (``currentEnvironment()``),
/// which records a dependency edge — so a body re-evaluates exactly when the environment it actually
/// reads changes (and no more). This is what lets memoized subtrees stay correct under fine-grained
/// reactivity: the environment is a tracked input, not a hidden global. (See
/// `project_hopui_finegrained_reactivity`.)

/// An action that presents the window registered for a given identifier. Mirrors SwiftUI's
/// `OpenWindowAction`; invoked as `openWindow(id: "about")`.
///
/// The initializer is left non-isolated so the default `EnvironmentValues.openWindow` value can be
/// constructed without main-actor isolation; only `callAsFunction` (which runs the handler) is
/// main-actor isolated.
public nonisolated struct OpenWindowAction {
    private let handler: (@MainActor (String) -> Void)?

    /// The default no-op action. nonisolated so it can be the default value of the (nonisolated)
    /// `EnvironmentValues.openWindow` without constructing a main-actor closure off the main actor.
    public init() { handler = nil }

    init(handler: @escaping @MainActor (String) -> Void) { self.handler = handler }

    @MainActor public func callAsFunction(id: String) { handler?(id) }
}

/// A key for accessing a custom environment value. Conform a type to this, then add a computed property
/// to `EnvironmentValues` that reads/writes `self[YourKey.self]`, exactly like SwiftUI:
///
/// ```swift
/// private struct GreetingKey: EnvironmentKey { static let defaultValue = "Hello" }
/// extension EnvironmentValues {
///     var greeting: String {
///         get { self[GreetingKey.self] }
///         set { self[GreetingKey.self] = newValue }
///     }
/// }
/// ```
///
/// The value then flows through `@Environment(\.greeting)` and `.environment(\.greeting, _)` like any
/// built-in value. Mirrors SwiftUI's `EnvironmentKey`.
public protocol EnvironmentKey {
    associatedtype Value
    // nonisolated so a user's key (written without `@MainActor`, like SwiftUI) and the read subscript work
    // from nonisolated contexts — e.g. `.environment(\.key, _)` forming a plain key path.
    nonisolated static var defaultValue: Value { get }
}

/// A collection of environment values. Mirrors SwiftUI's `EnvironmentValues`: it carries key-path
/// values (like `openWindow`), custom `EnvironmentKey` values (via `subscript(_:)`), and `@Observable`
/// reference objects keyed by their type.
///
/// `nonisolated` (like `Color`/`Font`) so it — and user-written extension properties for custom keys —
/// can be read and written off the main actor, e.g. when forming `.environment(\.key, _)` key paths.
public nonisolated struct EnvironmentValues {
    public init() {}

    /// The action that opens a registered secondary window. The runtime installs a working action in
    /// `runApp`; the default is a no-op so reads outside a running app are harmless.
    public var openWindow = OpenWindowAction()

    /// Dismisses the current presentation (e.g. a `.sheet`). A `.sheet` installs a working action into its
    /// content's environment; the default is a no-op. Read via `@Environment(\.dismiss)`.
    public var dismiss = DismissAction()

    /// The enclosing `NavigationStack`'s push action, installed by the stack while it evaluates its
    /// content so that a `NavigationLink` inside can append a value to the stack's path. `nil` outside
    /// a navigation stack.
    public var navigationPush: ((AnyHashable) -> Void)?

    /// Inherited text styling, set by `.font` / `.fontWeight` / `.foregroundStyle` and read by `Text`.
    public var font: Font?
    public var fontWeightOverride: Font.Weight?
    public var foregroundColor: Color?
    /// Inherited italic / monospaced traits (set by `.italic()` / `.monospaced()`) and multi-line text
    /// alignment (set by `.multilineTextAlignment(_:)`), all read by `Text`.
    public var fontItalicOverride: Bool = false
    public var fontMonospacedOverride: Bool = false
    public var multilineTextAlignment: TextAlignment = .leading

    /// The light/dark appearance, settable via `.environment(\.colorScheme, _)` and readable via
    /// `@Environment(\.colorScheme)`. Mirrors SwiftUI's `\.colorScheme`.
    public var colorScheme: ColorScheme = .light

    /// The presentation style for `Picker`s in this subtree, set via `.pickerStyle(_:)`. Read when a
    /// `Picker` builds its component, so it selects the native implementation (and is part of its widget key).
    public var pickerStyle: PickerStyle = .automatic

    /// The presentation style for `Toggle`s in this subtree, set via `.toggleStyle(_:)`. Read when a `Toggle`
    /// builds its component (part of its widget key) and when `Toggle.body` lays out the label.
    public var toggleStyle: ToggleStyle = .automatic

    /// Custom values injected by `EnvironmentKey`, keyed by the key type. Accessed through ``subscript(_:)``
    /// from the computed properties an extension adds for each key.
    private var keyedValues: [ObjectIdentifier: StoredEnvironmentValue] = [:]

    /// Reads or writes the value for a custom `EnvironmentKey`, falling back to the key's `defaultValue`
    /// when nothing has been injected. Mirrors SwiftUI's `EnvironmentValues.subscript(_:)`.
    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { (keyedValues[ObjectIdentifier(key)]?.value as? K.Value) ?? K.defaultValue }
        set { keyedValues[ObjectIdentifier(key)] = StoredEnvironmentValue(newValue) }
    }

    /// Objects injected via `.environment(_:)`, keyed by their dynamic type's identifier.
    private var objects: [ObjectIdentifier: Any] = [:]

    public mutating func setObject<T>(_ object: T) {
        objects[ObjectIdentifier(T.self)] = object
    }

    public func object<T>(_ type: T.Type) -> T? {
        objects[ObjectIdentifier(type)] as? T
    }

    /// Value equality used for memoization change-detection (`setValueIfChanged`). Compares the styling
    /// and injected objects that view bodies read; deliberately IGNORES the action closures
    /// (`openWindow`, `navigationPush`), which are recreated each pass but stable in behavior (they
    /// capture stable bindings). Injected objects are compared by identity, matching `@Observable`
    /// reference semantics — so re-deriving the same environment leaves dependents memoized.
    func sameEnvironment(as other: EnvironmentValues) -> Bool {
        guard font == other.font,
              fontWeightOverride == other.fontWeightOverride,
              foregroundColor == other.foregroundColor,
              fontItalicOverride == other.fontItalicOverride,
              fontMonospacedOverride == other.fontMonospacedOverride,
              multilineTextAlignment == other.multilineTextAlignment,
              colorScheme == other.colorScheme,
              pickerStyle == other.pickerStyle,
              toggleStyle == other.toggleStyle,
              (navigationPush == nil) == (other.navigationPush == nil),
              keyedValues.count == other.keyedValues.count,
              objects.count == other.objects.count else { return false }
        // Custom values compare by `==` when they're `Equatable` (the common case); a non-`Equatable`
        // value compares as changed, so dependents recompute rather than risk stale memoization.
        for (key, entry) in keyedValues {
            guard let otherEntry = other.keyedValues[key], entry.equals(otherEntry) else { return false }
        }
        for (key, value) in objects {
            guard let otherValue = other.objects[key],
                  (value as AnyObject) === (otherValue as AnyObject) else { return false }
        }
        return true
    }
}

/// A custom environment value plus a type-erased equality, captured when the value is `Equatable`, so the
/// environment's memoization comparison (``EnvironmentValues/sameEnvironment(as:)``) can detect changes.
nonisolated struct StoredEnvironmentValue {
    let value: Any
    /// True when this entry's value equals `other`'s. A non-`Equatable` value always reports unequal.
    let equals: (StoredEnvironmentValue) -> Bool

    init<V>(_ value: V) {
        self.value = value
        if let equatable = value as? any Equatable {
            self.equals = { equatable.isEqual(to: $0.value) }
        } else {
            self.equals = { _ in false }
        }
    }
}

private extension Equatable {
    /// Compares `self` to a type-erased value: equal only when `other` is the same type and `==`.
    nonisolated func isEqual(to other: Any) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

/// Holds the environment **attribute** for the current point in the view walk. Composite body rules
/// bracket the attribute they received; `.environment(_:)` / `.font` / `.foregroundStyle` derive a new
/// attribute for their subtree. Views read it through ``currentEnvironment()`` (recording a graph
/// dependency), not directly — so the environment is a tracked input, sound under memoization.
@MainActor
enum EnvironmentStore {
    static var currentAttr: Attribute<EnvironmentValues>?
    /// Fallback for evaluations performed outside the live environment chain (e.g. List row-text
    /// extraction against a throwaway context). The real environment always flows via `currentAttr`.
    static var fallback = EnvironmentValues()
}

/// Read the ambient environment through the graph. When called inside a body rule's evaluation, the
/// read records a dependency edge, so that body re-evaluates when the environment it reads changes —
/// and only then. Falls back to a default when no environment attribute is installed.
@MainActor
func currentEnvironment() -> EnvironmentValues {
    guard let attr = EnvironmentStore.currentAttr, let graph = GraphContext.current else {
        return EnvironmentStore.fallback
    }
    return graph.read(attr)
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
        let value = resolved(from: currentEnvironment())
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
