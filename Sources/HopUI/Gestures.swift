// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Tap gestures, mirroring SwiftUI's `.onTapGesture(count:perform:)`. The handler is a cross-cutting
// attachment on the wrapped view's ``RenderNode`` (like `.fileImporter`/`.onScroll`); each backend
// installs a native tap/click recognizer on the widget that invokes it (NSClickGestureRecognizer /
// GtkGestureClick / a Qt event filter / WinUI's Tapped event).

/// A tap-gesture handler attached via `.onTapGesture`: how many taps are required and what to run. Public
/// so the per-backend toolkits (separate modules) can read it when wiring the native recognizer.
public struct TapGestureSpec {
    /// Number of taps required to fire (1 = single tap, 2 = double tap). Mirrors `.onTapGesture(count:)`.
    public let count: Int
    public let action: @MainActor () -> Void
    public init(count: Int, action: @escaping @MainActor () -> Void) {
        self.count = count
        self.action = action
    }
}

/// Attaches a tap handler to the wrapped view's node. Mirrors `_AccessibilityModifier`/`_FileImporterModifier`:
/// it lands the handler on the content's first rendered node (and is carried onto a composite via
/// ``RenderNode/applyWrapperState(from:)``).
struct _TapGestureModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let spec: TapGestureSpec

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.onTap = spec
        return node
    }
}

extension View {
    /// Runs `action` when the view is tapped `count` times. Mirrors SwiftUI's
    /// `.onTapGesture(count:perform:)`, so the same call site compiles against HopUI and Apple's SwiftUI.
    public func onTapGesture(count: Int = 1, perform action: @escaping @MainActor () -> Void) -> some View {
        _TapGestureModifier(content: self, spec: TapGestureSpec(count: count, action: action))
    }
}

// MARK: - Long press & hover (closure modifiers, like SwiftUI's convenience forms)

/// A long-press handler attached via `.onLongPressGesture`. The toolkit fires `action` once the press is
/// held for `minimumDuration`. Public so the per-backend toolkits can read it.
public struct LongPressGestureSpec {
    public let minimumDuration: Double
    public let action: @MainActor () -> Void
    public init(minimumDuration: Double, action: @escaping @MainActor () -> Void) {
        self.minimumDuration = minimumDuration
        self.action = action
    }
}

struct _LongPressGestureModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let spec: LongPressGestureSpec
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.onLongPress = spec
        return node
    }
}

struct _HoverGestureModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let action: @MainActor (Bool) -> Void
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.onHover = action
        return node
    }
}

extension View {
    /// Runs `action` when the view is pressed and held for at least `minimumDuration` seconds. Mirrors
    /// SwiftUI's `.onLongPressGesture(minimumDuration:perform:)`.
    public func onLongPressGesture(minimumDuration: Double = 0.5, perform action: @escaping @MainActor () -> Void) -> some View {
        _LongPressGestureModifier(content: self, spec: LongPressGestureSpec(minimumDuration: minimumDuration, action: action))
    }
    /// Runs `action(true)` when the pointer enters the view and `action(false)` when it leaves. Mirrors
    /// SwiftUI's `.onHover(perform:)`.
    public func onHover(perform action: @escaping @MainActor (Bool) -> Void) -> some View {
        _HoverGestureModifier(content: self, action: action)
    }
}

// MARK: - Value-carrying gestures (the `Gesture` protocol + `.gesture(_:)`)

/// The toolkit-facing payload a ``Gesture`` lands on a node via `.gesture(_:)`.
public enum GestureAttachment {
    case drag(DragGestureSpec)
    case magnify(MagnifyGestureSpec)
    case rotate(RotateGestureSpec)
}

/// A continuous, value-carrying gesture. Mirrors (a minimal slice of) SwiftUI's `Gesture`: concrete
/// gestures (`DragGesture`/`MagnifyGesture`/`RotateGesture`) carry `onChanged`/`onEnded` callbacks and are
/// attached with `.gesture(_:)`. The combinator algebra (`SequenceGesture`, `@GestureState`, …) is omitted.
public protocol Gesture {
    associatedtype Value
    var _attachment: GestureAttachment { get }
}

public struct DragGestureSpec {
    public let minimumDistance: CGFloat
    public let onChanged: (@MainActor (DragGesture.Value) -> Void)?
    public let onEnded: (@MainActor (DragGesture.Value) -> Void)?
}
public struct MagnifyGestureSpec {
    public let onChanged: (@MainActor (MagnifyGesture.Value) -> Void)?
    public let onEnded: (@MainActor (MagnifyGesture.Value) -> Void)?
}
public struct RotateGestureSpec {
    public let onChanged: (@MainActor (RotateGesture.Value) -> Void)?
    public let onEnded: (@MainActor (RotateGesture.Value) -> Void)?
}

/// A dragging gesture. Mirrors SwiftUI's `DragGesture`; `Value` exposes the common `startLocation` /
/// `location` / `translation` members so closures compile against both HopUI and SwiftUI.
public struct DragGesture: Gesture {
    public struct Value: Equatable, Sendable {
        public var startLocation: CGPoint
        public var location: CGPoint
        public var translation: CGSize
        public init(startLocation: CGPoint, location: CGPoint, translation: CGSize) {
            self.startLocation = startLocation; self.location = location; self.translation = translation
        }
    }
    public var minimumDistance: CGFloat
    private var changed: (@MainActor (Value) -> Void)?
    private var ended: (@MainActor (Value) -> Void)?
    public init(minimumDistance: CGFloat = 10) { self.minimumDistance = minimumDistance }
    public func onChanged(_ action: @escaping @MainActor (Value) -> Void) -> DragGesture { var g = self; g.changed = action; return g }
    public func onEnded(_ action: @escaping @MainActor (Value) -> Void) -> DragGesture { var g = self; g.ended = action; return g }
    public var _attachment: GestureAttachment { .drag(DragGestureSpec(minimumDistance: minimumDistance, onChanged: changed, onEnded: ended)) }
}

/// A pinch-to-zoom (magnification) gesture. Mirrors SwiftUI's `MagnifyGesture`; `Value.magnification` is the
/// scale factor (1.0 = no change).
public struct MagnifyGesture: Gesture {
    public struct Value: Equatable, Sendable {
        public var magnification: CGFloat
        public init(magnification: CGFloat) { self.magnification = magnification }
    }
    public var minimumScaleDelta: CGFloat
    private var changed: (@MainActor (Value) -> Void)?
    private var ended: (@MainActor (Value) -> Void)?
    public init(minimumScaleDelta: CGFloat = 0.01) { self.minimumScaleDelta = minimumScaleDelta }
    public func onChanged(_ action: @escaping @MainActor (Value) -> Void) -> MagnifyGesture { var g = self; g.changed = action; return g }
    public func onEnded(_ action: @escaping @MainActor (Value) -> Void) -> MagnifyGesture { var g = self; g.ended = action; return g }
    public var _attachment: GestureAttachment { .magnify(MagnifyGestureSpec(onChanged: changed, onEnded: ended)) }
}

/// A two-finger rotation gesture. Mirrors SwiftUI's `RotateGesture`; `Value.rotation` is an `Angle`.
public struct RotateGesture: Gesture {
    public struct Value: Equatable, Sendable {
        public var rotation: Angle
        public init(rotation: Angle) { self.rotation = rotation }
    }
    public var minimumAngleDelta: Angle
    private var changed: (@MainActor (Value) -> Void)?
    private var ended: (@MainActor (Value) -> Void)?
    public init(minimumAngleDelta: Angle = .degrees(1)) { self.minimumAngleDelta = minimumAngleDelta }
    public func onChanged(_ action: @escaping @MainActor (Value) -> Void) -> RotateGesture { var g = self; g.changed = action; return g }
    public func onEnded(_ action: @escaping @MainActor (Value) -> Void) -> RotateGesture { var g = self; g.ended = action; return g }
    public var _attachment: GestureAttachment { .rotate(RotateGestureSpec(onChanged: changed, onEnded: ended)) }
}

struct _GestureModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let attachment: GestureAttachment
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        switch attachment {
        case .drag(let spec): node.dragGesture = spec
        case .magnify(let spec): node.magnifyGesture = spec
        case .rotate(let spec): node.rotateGesture = spec
        }
        return node
    }
}

extension View {
    /// Attaches a value-carrying gesture (`DragGesture`/`MagnifyGesture`/`RotateGesture`). Mirrors SwiftUI's
    /// `.gesture(_:)`.
    public func gesture<G: Gesture>(_ gesture: G) -> some View {
        _GestureModifier(content: self, attachment: gesture._attachment)
    }
}
