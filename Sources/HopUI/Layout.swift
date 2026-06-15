// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// HopUI's framework-owned layout engine: a faithful SwiftUI "parent proposes a size, child chooses its
// size" model. The engine computes a frame (origin + size) for every node and tells the backend to place
// each widget absolutely (`setFrame`), measuring leaf widgets via the backend (`measure`). Backends use
// plain absolute-positioning containers instead of native stack/box layout, so geometry is identical
// across AppKit / GTK4 / Qt. Native composite widgets (List, the split view) keep their own internal
// layout; the engine only sizes their outer frame.

#if canImport(Foundation)
import Foundation  // sqrt-free; only for nextUp-style helpers if needed
#endif

// MARK: - Geometry value types (SwiftUI-mirroring)

/// A size offered to a view by its parent. `nil` on an axis means "unspecified — choose your ideal size".
public struct ProposedViewSize: Equatable, Sendable {
    public var width: Double?
    public var height: Double?
    public init(width: Double?, height: Double?) { self.width = width; self.height = height }
    public init(_ size: CGSize) { self.width = Double(size.width); self.height = Double(size.height) }

    public static let unspecified = ProposedViewSize(width: nil, height: nil)
    public static let zero = ProposedViewSize(width: 0, height: 0)
    public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)

    /// Replace unspecified axes with a fallback.
    public func resolved(_ fallback: CGSize) -> CGSize {
        CGSize(width: CGFloat(width ?? Double(fallback.width)), height: CGFloat(height ?? Double(fallback.height)))
    }
}

/// Insets for the four edges of a rectangle. Mirrors SwiftUI's `EdgeInsets`.
public struct EdgeInsets: Equatable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    public static let zero = EdgeInsets()
    var horizontal: Double { leading + trailing }
    var vertical: Double { top + bottom }
}

/// A set of rectangle edges, for `.padding(_:_:)`. Mirrors SwiftUI's `Edge.Set`.
public enum Edge: Int, Sendable, CaseIterable {
    case top, leading, bottom, trailing

    public struct Set: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1 << 0)
        public static let leading = Set(rawValue: 1 << 1)
        public static let bottom = Set(rawValue: 1 << 2)
        public static let trailing = Set(rawValue: 1 << 3)
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
        public static let all: Set = [.top, .leading, .bottom, .trailing]
    }
}

/// Horizontal alignment guide. Mirrors SwiftUI's `HorizontalAlignment`.
public enum HorizontalAlignment: Sendable { case leading, center, trailing }
/// Vertical alignment guide. Mirrors SwiftUI's `VerticalAlignment`.
public enum VerticalAlignment: Sendable { case top, center, bottom }

/// A 2D alignment. Mirrors SwiftUI's `Alignment`.
public struct Alignment: Equatable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal; self.vertical = vertical
    }
    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)

    func xOffset(child: CGFloat, in container: CGFloat) -> CGFloat {
        switch horizontal {
        case .leading: return 0
        case .center: return (container - child) / 2
        case .trailing: return container - child
        }
    }
    func yOffset(child: CGFloat, in container: CGFloat) -> CGFloat {
        switch vertical {
        case .top: return 0
        case .center: return (container - child) / 2
        case .bottom: return container - child
        }
    }
}

/// The axis of a stack/scroll. Mirrors SwiftUI's `Axis`.
public enum Axis: Sendable { case horizontal, vertical }

// MARK: - Node layout description

/// A `.frame(...)` request: fixed and/or min/ideal/max bounds plus an alignment for the content inside.
public struct FrameSpec: Equatable, Sendable {
    public var width: Double?
    public var height: Double?
    public var minWidth: Double?
    public var maxWidth: Double?
    public var minHeight: Double?
    public var maxHeight: Double?
    public var alignment: Alignment
    public init(width: Double? = nil, height: Double? = nil,
                minWidth: Double? = nil, maxWidth: Double? = nil,
                minHeight: Double? = nil, maxHeight: Double? = nil,
                alignment: Alignment = .center) {
        self.width = width; self.height = height
        self.minWidth = minWidth; self.maxWidth = maxWidth
        self.minHeight = minHeight; self.maxHeight = maxHeight
        self.alignment = alignment
    }
}

/// A unary layout modifier wrapping a node — composed in order (innermost first).
public enum LayoutModifier: Equatable, Sendable {
    case padding(EdgeInsets)
    case frame(FrameSpec)
}

/// The engine-internal layout behavior for a node. Derived from the node's ``WidgetKind`` (so internally
/// produced containers — Navigation bars, modifier wrappers — get stack/zstack layout automatically),
/// parameterized by the extras in ``LayoutInfo`` (alignment, spacing, spacer length).
enum LayoutRole {
    /// A leaf whose size is measured by the backend (text, button, slider, shape, …).
    case leaf
    /// A stack along an axis: lay children out in sequence, distributing extra space to spacers.
    case stack(axis: Axis, spacing: Double?, alignment: Alignment)
    /// Overlapping children, each sized against the full proposal, aligned within the stack's bounds.
    case zstack(alignment: Alignment)
    /// A flexible gap that expands along its stack's axis.
    case spacer(minLength: Double)
    /// A native composite widget (List, split view): the engine sizes its outer frame; the widget lays
    /// out its own internals (and the engine lays out content inside each of its panes — see the runtime).
    case native
    /// A scroll viewport (engine sizes the viewport; its single content child is laid out at its natural
    /// size and the backend scrolls it).
    case scroll(axis: Axis)
    /// A ``GeometryReader``: fills the offered space and reports its size back (via the node's
    /// `onGeometry`) so content can react to the available geometry. Its single child fills it.
    case geometry
    /// A virtualizing ``LazyVStack``/``LazyHStack``: sized to the full row count, but only the visible
    /// window of rows is materialized; each row is positioned at its `lazyIndex` offset.
    case lazyStack(LazyInfo, alignment: Alignment)
}

/// Per-node layout metadata carried on a ``RenderNode``. The role itself is derived from the node's
/// `WidgetKind`; this only carries the configurable extras a view's `makeNode` sets.
public struct LayoutInfo: Equatable, Sendable {
    /// Unary modifiers (padding, frame) wrapping the node, innermost first.
    public var modifiers: [LayoutModifier]
    /// Stack/zstack alignment (nil → centered cross-axis).
    public var alignment: Alignment?
    /// Minimum length for a `Spacer`.
    public var spacerMinLength: Double
    /// Scroll axis for a `ScrollView` (nil → vertical).
    public var scrollAxis: Axis?
    /// This child's index within an enclosing `LazyVStack`/`LazyHStack` (nil → not a lazy row), so the
    /// engine can position it at its absolute offset even though only a window of rows is materialized.
    public var lazyIndex: Int?
    /// Lazy-stack virtualization parameters (used when the node's kind is `.lazyStack`).
    public var lazy: LazyInfo?
    public init(modifiers: [LayoutModifier] = [], alignment: Alignment? = nil,
                spacerMinLength: Double = 0, scrollAxis: Axis? = nil,
                lazyIndex: Int? = nil, lazy: LazyInfo? = nil) {
        self.modifiers = modifiers
        self.alignment = alignment
        self.spacerMinLength = spacerMinLength
        self.scrollAxis = scrollAxis
        self.lazyIndex = lazyIndex
        self.lazy = lazy
    }
}

/// Virtualization parameters for a `LazyVStack`/`LazyHStack`: the axis, the (uniform) per-row extent
/// along that axis, the inter-row spacing, and the total row count. The engine uses these to size the
/// full scrollable content (so the scrollbar is correct) even though only the visible rows exist.
public struct LazyInfo: Equatable, Sendable {
    public var axis: Axis
    public var rowExtent: Double
    public var spacing: Double
    public var totalCount: Int
    public init(axis: Axis, rowExtent: Double, spacing: Double, totalCount: Int) {
        self.axis = axis
        self.rowExtent = rowExtent
        self.spacing = spacing
        self.totalCount = totalCount
    }
}

/// The default spacing between stack children when none is specified (SwiftUI uses 8pt).
let hopDefaultSpacing: Double = 8
