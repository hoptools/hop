// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// A piece of the user interface. Mirrors SwiftUI's `View`.
///
/// Composite views describe themselves in terms of other views via ``body``. Primitive views
/// (``Text``, ``Button``, ``VStack``, ``HStack``) instead conform to the internal `PrimitiveView`
/// protocol and produce a ``RenderNode`` directly; their `Body` is `Never`.
@MainActor
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

/// `Never` is the `Body` type of primitive/leaf views, which never have their `body` accessed.
extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError("Never has no body") }
}

/// An empty view that contributes nothing to the render tree.
public struct EmptyView: View {
    public init() {}
    public typealias Body = Never
    public var body: Never { fatalError("EmptyView has no body") }
}

/// A view assembled from several child views by ``ViewBuilder``.
public struct TupleView: View, AnyTupleView {
    let childViews: [any View]
    init(_ childViews: [any View]) { self.childViews = childViews }
    public typealias Body = Never
    public var body: Never { fatalError("TupleView has no body") }
}

/// Internal protocol letting the evaluator flatten a ``TupleView`` into its children.
@MainActor
protocol AnyTupleView {
    var childViews: [any View] { get }
}

/// Result builder that assembles `@ViewBuilder` closures into a single ``View``.
@resultBuilder
@MainActor
public enum ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }

    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }

    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView {
        var views: [any View] = []
        repeat views.append(each content)
        return TupleView(views)
    }

    public static func buildOptional<Content: View>(_ content: Content?) -> OptionalView<Content> {
        OptionalView(content)
    }

    public static func buildEither<First: View, Second: View>(first content: First) -> _ConditionalContent<First, Second> {
        _ConditionalContent<First, Second>.first(content)
    }
    public static func buildEither<First: View, Second: View>(second content: Second) -> _ConditionalContent<First, Second> {
        _ConditionalContent<First, Second>.second(content)
    }
}

/// The result of an `if`/`else` (or `switch`) in a `@ViewBuilder`. Mirrors SwiftUI's
/// `_ConditionalContent`. The two arms carry different branch identities, so switching arms tears down
/// the old arm's widgets (and state) and builds the new arm fresh — matching SwiftUI.
public enum _ConditionalContent<TrueContent: View, FalseContent: View>: View, AnyConditionalContent {
    case first(TrueContent)
    case second(FalseContent)

    public typealias Body = Never
    public var body: Never { fatalError("_ConditionalContent has no body") }

    var conditionalBranch: Int { if case .first = self { return 0 } else { return 1 } }
    var conditionalContent: any View {
        switch self {
        case .first(let content): return content
        case .second(let content): return content
        }
    }
}

/// Internal protocol letting the evaluator tag each arm of an `if`/`else` with a distinct identity.
@MainActor
protocol AnyConditionalContent {
    var conditionalBranch: Int { get }
    var conditionalContent: any View { get }
}

/// A view tagged with an explicit identity via ``View/id(_:)``. Changing the value gives the subtree a
/// new identity (state resets); a stable value preserves it across reordering.
public struct IDView<Content: View>: View, AnyIDView {
    let content: Content
    let value: AnyHashable

    public typealias Body = Never
    public var body: Never { fatalError("IDView has no body") }

    var idValue: AnyHashable { value }
    var idContent: any View { content }
}

/// Internal protocol letting the evaluator read a view's explicit `.id(_:)` identity.
@MainActor
protocol AnyIDView {
    var idValue: AnyHashable { get }
    var idContent: any View { get }
}

extension View {
    /// Binds an explicit identity to the view. Mirrors SwiftUI's `.id(_:)`.
    public func id<ID: Hashable>(_ id: ID) -> some View {
        IDView(content: self, value: AnyHashable(id))
    }
}

/// Wraps an optional child produced by an `if` without `else` in a `@ViewBuilder`.
public struct OptionalView<Wrapped: View>: View, AnyTupleView {
    let wrapped: Wrapped?
    init(_ wrapped: Wrapped?) { self.wrapped = wrapped }
    var childViews: [any View] { wrapped.map { [$0] } ?? [] }
    public typealias Body = Never
    public var body: Never { fatalError("OptionalView has no body") }
}
