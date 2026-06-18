// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// The layout pass: walks a RenderNode tree, computes a size for each node (measuring leaves through the
// toolkit) and a frame for each widget, applying the SwiftUI "parent proposes / child chooses" contract
// plus the unary modifier chain (padding, frame). It is toolkit-agnostic — `measureLeaf` and `setFrame`
// are supplied by the runtime (wired to the reconciler's id→handle map).

struct LayoutEngine {
    /// Measure a leaf/native widget's chosen size for a proposal (toolkit intrinsic sizing).
    let measureLeaf: (RenderNode, ProposedViewSize) -> CGSize
    /// Position a node's widget at an absolute frame in its parent's coordinate space.
    let setFrame: (RenderNode, CGRect) -> Void
    /// The current native size of a node's widget (for laying out content inside native composites).
    var sizeOf: (RenderNode) -> CGSize = { _ in .zero }

    /// The layout behavior of a node, from its ``WidgetComponent``'s role.
    private func role(of node: RenderNode) -> LayoutRole {
        switch node.component.role {
        case .leaf, .fill: return .leaf
        case .native: return .native
        case .spacer(let m): return .spacer(minLength: m)
        case .stack(let a, let s, let al): return .stack(axis: a, spacing: s, alignment: al)
        case .zstack(let al): return .zstack(alignment: al)
        case .scroll(let axis): return .scroll(axis: axis)
        case .geometry: return .geometry
        case .lazyStack(let info, let al): return .lazyStack(info, alignment: al)
        }
    }

    // MARK: size

    /// The size `node` chooses for `proposal`, accounting for its modifier chain.
    func size(_ node: RenderNode, _ proposal: ProposedViewSize) -> CGSize {
        sizeMods(node, node.layout.modifiers.count - 1, proposal)
    }

    private func sizeMods(_ node: RenderNode, _ i: Int, _ proposal: ProposedViewSize) -> CGSize {
        guard i >= 0 else { return sizeCore(node, proposal) }
        switch node.layout.modifiers[i] {
        case .padding(let insets):
            let inner = ProposedViewSize(
                width: proposal.width.map { Swift.max(0, $0 - insets.horizontal) },
                height: proposal.height.map { Swift.max(0, $0 - insets.vertical) })
            let s = sizeMods(node, i - 1, inner)
            return CGSize(width: s.width + CGFloat(insets.horizontal), height: s.height + CGFloat(insets.vertical))
        case .frame(let f):
            let innerProposal = ProposedViewSize(
                width: f.width ?? clamp(proposal.width, f.minWidth, f.maxWidth),
                height: f.height ?? clamp(proposal.height, f.minHeight, f.maxHeight))
            let content = sizeMods(node, i - 1, innerProposal)
            return CGSize(
                width: resolveAxis(fixed: f.width, min: f.minWidth, max: f.maxWidth, proposal: proposal.width, content: Double(content.width)),
                height: resolveAxis(fixed: f.height, min: f.minHeight, max: f.maxHeight, proposal: proposal.height, content: Double(content.height)))
        }
    }

    private func sizeCore(_ node: RenderNode, _ proposal: ProposedViewSize) -> CGSize {
        switch role(of: node) {
        case .leaf:
            return measureLeaf(node, proposal)
        case .native:
            // Native composites (list, split) fill the offered space; the widget lays out its own internals.
            return proposal.resolved(.zero)
        case .scroll, .geometry:
            // A scroll viewport / geometry reader greedily takes the offered space.
            return proposal.resolved(CGSize(width: 100, height: 100))
        case .spacer:
            return .zero  // a spacer's extent is decided by its enclosing stack
        case .stack(let axis, let spacing, let alignment):
            return stackLayout(node.children, axis: axis, spacing: spacing, alignment: alignment, proposal).total
        case .zstack(let alignment):
            return zstackLayout(node.children, alignment: alignment, proposal).total
        case .lazyStack(let lazy, _):
            // Sized to the FULL content (all rows), so the enclosing scroll's content/scrollbar is
            // correct even though only the visible window of rows is materialized.
            let along = Double(lazy.totalCount) * lazy.rowExtent
                + Double(Swift.max(0, lazy.totalCount - 1)) * lazy.spacing
            let vertical = lazy.axis == .vertical
            let crossProposal = vertical ? proposal.width : proposal.height
            var maxCross = 0.0
            for child in node.children {
                let cp = vertical ? ProposedViewSize(width: crossProposal, height: nil)
                                  : ProposedViewSize(width: nil, height: crossProposal)
                let s = size(child, cp)
                maxCross = Swift.max(maxCross, Double(vertical ? s.width : s.height))
            }
            let cross = crossProposal ?? maxCross
            return vertical ? CGSize(width: cross, height: along) : CGSize(width: along, height: cross)
        }
    }

    // MARK: place

    /// Place `node`'s widget at `rect` (parent coordinates) and recursively place its children.
    func place(_ node: RenderNode, _ rect: CGRect) {
        placeMods(node, node.layout.modifiers.count - 1, rect)
    }

    private func placeMods(_ node: RenderNode, _ i: Int, _ rect: CGRect) {
        guard i >= 0 else { placeCore(node, rect); return }
        switch node.layout.modifiers[i] {
        case .padding(let insets):
            placeMods(node, i - 1, rect.inset(by: insets))
        case .frame(let f):
            // The content takes its chosen size within the frame rect, positioned by the frame's alignment.
            let content = sizeMods(node, i - 1, ProposedViewSize(rect.size))
            let x = rect.minX + f.alignment.xOffset(child: content.width, in: rect.width)
            let y = rect.minY + f.alignment.yOffset(child: content.height, in: rect.height)
            placeMods(node, i - 1, CGRect(x: x, y: y, width: content.width, height: content.height))
        }
    }

    private func placeCore(_ node: RenderNode, _ rect: CGRect) {
        setFrame(node, rect)
        // Children are positioned in this widget's LOCAL coordinate space (origin at its top-left).
        let local = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        switch role(of: node) {
        case .leaf, .spacer:
            break  // no engine-positioned children
        case .native:
            // The native widget (split view) positions its own panes; lay out each pane's CONTENT within
            // the pane's native size. (For List there are no engine-laid-out children.)
            //
            // A NavigationSplitView is special: the detail must be laid out within the REMAINING width
            // (split width − sidebar), capped against its native size — NOT purely `sizeOf(detail)`. The
            // engine pins the detail content's size, which a backend may treat as the detail pane's minimum
            // (e.g. GtkPaned + GtkFixed allocate a child its natural size); that makes the pane unable to
            // shrink, so `sizeOf(detail)` stays stale-large and the content never re-fits a shrinking
            // window. The sidebar doesn't resize, so its width is stable and `split − sidebar` is reliable.
            if node.component.widgetKey == .splitView, node.children.count == 2 {
                let sidebarSize = sizeOf(node.children[0])
                layoutPaneContent(node.children[0], sidebarSize)
                let detailNative = sizeOf(node.children[1])
                let available = Swift.max(0, local.width - sidebarSize.width)
                layoutPaneContent(node.children[1], CGSize(width: Swift.min(detailNative.width, available), height: detailNative.height))
            } else {
                for child in node.children { layoutPaneContent(child, sizeOf(child)) }
            }
        case .scroll:
            // Report the viewport size back so a ScrollView's virtualized content knows its visible range.
            node.onGeometry?(local.size)
            // The single content child is laid out at its natural size along the scroll axis (the viewport
            // proposes its cross size but leaves the scroll axis unbounded), pinned to the top-left.
            guard let content = node.children.first else { break }
            let axisVertical = { if case .scroll(let a) = role(of: node) { return a == .vertical }; return true }()
            let proposal = axisVertical
                ? ProposedViewSize(width: Double(local.width), height: nil)
                : ProposedViewSize(width: nil, height: Double(local.height))
            let s = size(content, proposal)
            place(content, CGRect(x: 0, y: 0, width: max(s.width, local.width), height: max(s.height, local.height)))
        case .stack(let axis, let spacing, let alignment):
            let layout = stackLayout(node.children, axis: axis, spacing: spacing, alignment: alignment, ProposedViewSize(local.size))
            for (child, childRect) in zip(node.children, layout.rects) { place(child, childRect) }
        case .zstack(let alignment):
            let layout = zstackLayout(node.children, alignment: alignment, ProposedViewSize(local.size))
            for (child, childRect) in zip(node.children, layout.rects) { place(child, childRect) }
        case .geometry:
            // Report the laid-out size to the GeometryReader (which feeds it back to its content via a
            // graph source). The content is offered the full size but placed at its OWN chosen size in the
            // top-leading corner (matching SwiftUI — a non-greedy child keeps its natural size, a greedy one
            // fills), rather than being stretched to the reader's bounds.
            node.onGeometry?(local.size)
            if let content = node.children.first {
                let s = size(content, ProposedViewSize(local.size))
                place(content, CGRect(x: 0, y: 0, width: s.width, height: s.height))
            }
        case .lazyStack(let lazy, let alignment):
            // Report the lazy stack's top within its parent (≈ its offset within the enclosing scroll's
            // content) so it can window relative to itself when it sits below other content.
            node.onContentOrigin?(Double(rect.minY))
            placeLazyStack(node, lazy: lazy, alignment: alignment, in: local)
        }
    }

    /// Position the materialized window of rows at their absolute per-index offsets, and report the first
    /// row's measured extent back so the (uniform) row-size estimate converges.
    private func placeLazyStack(_ node: RenderNode, lazy: LazyInfo, alignment: Alignment, in local: CGRect) {
        let vertical = lazy.axis == .vertical
        let stride = lazy.rowExtent + lazy.spacing
        let crossExtent = vertical ? Double(local.width) : Double(local.height)
        var firstExtent: Double?
        for child in node.children {
            guard let idx = child.layout.lazyIndex else { continue }
            let cp = vertical ? ProposedViewSize(width: crossExtent, height: nil)
                              : ProposedViewSize(width: nil, height: crossExtent)
            let s = size(child, cp)
            if firstExtent == nil { firstExtent = Double(vertical ? s.height : s.width) }
            let along = Double(idx) * stride
            if vertical {
                let x = alignment.xOffset(child: s.width, in: CGFloat(crossExtent))
                place(child, CGRect(x: x, y: along, width: s.width, height: s.height))
            } else {
                let y = alignment.yOffset(child: s.height, in: CGFloat(crossExtent))
                place(child, CGRect(x: along, y: y, width: s.width, height: s.height))
            }
        }
        if let firstExtent { node.onRowExtent?(firstExtent) }
    }

    /// Lay out a node's children within `size` WITHOUT re-framing the node itself — used for content inside
    /// a native composite's pane (the native widget already positioned the pane).
    func layoutPaneContent(_ node: RenderNode, _ size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        switch role(of: node) {
        case .stack(let axis, let spacing, let alignment):
            let layout = stackLayout(node.children, axis: axis, spacing: spacing, alignment: alignment, ProposedViewSize(size))
            for (child, childRect) in zip(node.children, layout.rects) { place(child, childRect) }
        case .zstack(let alignment):
            // As a native pane's root, a ZStack fills the pane and aligns each child within the full area
            // (unlike a free ZStack, which shrinks to its largest child) — so e.g. TabView pages center.
            for child in node.children {
                let s = self.size(child, ProposedViewSize(size))
                // Clamp the centering offset to ≥ 0: if the pane size isn't known yet (e.g. a GtkNotebook
                // page allocates lazily and reports 0), fall back to top-leading rather than negative
                // coords that would overlap the tab strip. Where the size is known, the content centers.
                let x = Swift.max(0, alignment.xOffset(child: s.width, in: size.width))
                let y = Swift.max(0, alignment.yOffset(child: s.height, in: size.height))
                place(child, CGRect(x: x, y: y, width: s.width, height: s.height))
            }
        case .native:
            for child in node.children { layoutPaneContent(child, sizeOf(child)) }
        case .scroll, .geometry, .lazyStack:
            placeCore(node, rect)  // these lay their content out normally relative to (0,0)
        case .leaf, .spacer:
            break
        }
    }

    // MARK: stack / zstack algorithms

    private func stackLayout(_ children: [RenderNode], axis: Axis, spacing spacingOpt: Double?,
                             alignment: Alignment, _ proposal: ProposedViewSize) -> (total: CGSize, rects: [CGRect]) {
        let spacing = CGFloat(spacingOpt ?? hopDefaultSpacing)
        let horizontal = axis == .horizontal
        let crossProposal = horizontal ? proposal.height : proposal.width
        let alongProposal = horizontal ? proposal.width : proposal.height

        var along = [CGFloat](repeating: 0, count: children.count)
        var cross = [CGFloat](repeating: 0, count: children.count)
        var spacer = [Bool](repeating: false, count: children.count)  // a Spacer (no spacing around it)
        var flex = [Bool](repeating: false, count: children.count)    // expands along the main axis
        for (i, child) in children.enumerated() {
            spacer[i] = isSpacer(child)
            flex[i] = greedyAlong(child, axis)
            if spacer[i] { continue }
            // Measure cross always; measure along too (the ideal extent — a flex child uses it only as a
            // fallback when there's no concrete space to distribute).
            let childProposal = horizontal
                ? ProposedViewSize(width: nil, height: crossProposal)
                : ProposedViewSize(width: crossProposal, height: nil)
            let s = size(child, childProposal)
            along[i] = horizontal ? s.width : s.height
            cross[i] = horizontal ? s.height : s.width
        }
        // Spacing only between adjacent non-spacer children (a Spacer provides its own gap).
        var gaps: CGFloat = 0
        if children.count > 1 {
            for i in 1 ..< children.count where !spacer[i] && !spacer[i - 1] { gaps += spacing }
        }
        // Distribute leftover main-axis space equally among flex children (Spacers + greedy content like
        // ScrollView / .frame(maxHeight: .infinity)). With no concrete main-axis size, Spacers collapse to
        // their minimum and greedy content keeps its ideal extent.
        let flexIdxs = (0 ..< children.count).filter { flex[$0] }
        if let alongAvail = alongProposal, !flexIdxs.isEmpty {
            let nonFlexAlong = (0 ..< children.count).filter { !flex[$0] }.reduce(CGFloat(0)) { $0 + along[$1] }
            let leftover = Swift.max(0, CGFloat(alongAvail) - nonFlexAlong - gaps)
            let per = leftover / CGFloat(flexIdxs.count)
            for i in flexIdxs { along[i] = spacer[i] ? Swift.max(spacerMinLength(children[i]), per) : per }
        } else {
            for i in flexIdxs where spacer[i] { along[i] = spacerMinLength(children[i]) }
        }
        let contentAlong = along.reduce(0, +) + gaps
        let totalAlong = (!flexIdxs.isEmpty && alongProposal != nil) ? CGFloat(alongProposal!) : contentAlong
        let totalCross = cross.max() ?? 0

        var offset: CGFloat = 0
        var rects: [CGRect] = []
        for (i, _) in children.enumerated() {
            if i > 0 && !spacer[i] && !spacer[i - 1] { offset += spacing }
            let a = along[i], c = cross[i]
            let crossOffset = crossAlign(alignment, horizontal: horizontal, child: c, in: totalCross)
            rects.append(horizontal
                ? CGRect(x: offset, y: crossOffset, width: a, height: c)
                : CGRect(x: crossOffset, y: offset, width: c, height: a))
            offset += a
        }
        let total = horizontal ? CGSize(width: totalAlong, height: totalCross) : CGSize(width: totalCross, height: totalAlong)
        return (total, rects)
    }

    /// Whether `node` expands to fill leftover space along a stack's main `axis` (gets a share of the
    /// distributed space rather than its ideal extent). The OUTERMOST `.frame` decides when present (a
    /// fixed size is rigid; `max…: .infinity` fills); otherwise Spacer / ScrollView / GeometryReader fill.
    private func greedyAlong(_ node: RenderNode, _ axis: Axis) -> Bool {
        for modifier in node.layout.modifiers.reversed() {  // outermost first
            if case .frame(let f) = modifier {
                let fixed = axis == .vertical ? f.height : f.width
                let maxValue = axis == .vertical ? f.maxHeight : f.maxWidth
                if fixed != nil { return false }       // a fixed size is rigid
                return maxValue == .infinity            // fills only with an explicit max-infinity
            }
        }
        switch node.component.role { case .fill, .spacer, .scroll, .geometry: return true; default: return false }
    }

    /// Whether a node is a Spacer (via its component role).
    private func isSpacer(_ node: RenderNode) -> Bool {
        if case .spacer = node.component.role { return true }
        return false
    }

    private func zstackLayout(_ children: [RenderNode], alignment: Alignment,
                              _ proposal: ProposedViewSize) -> (total: CGSize, rects: [CGRect]) {
        let sizes = children.map { size($0, proposal) }
        let w = sizes.map(\.width).max() ?? 0
        let h = sizes.map(\.height).max() ?? 0
        let rects = sizes.map { s in
            CGRect(x: alignment.xOffset(child: s.width, in: w), y: alignment.yOffset(child: s.height, in: h),
                   width: s.width, height: s.height)
        }
        return (CGSize(width: w, height: h), rects)
    }

    private func spacerMinLength(_ node: RenderNode) -> CGFloat {
        if case .spacer(let m) = node.component.role { return CGFloat(m) }
        return 0
    }

    private func crossAlign(_ alignment: Alignment, horizontal: Bool, child: CGFloat, in container: CGFloat) -> CGFloat {
        // The cross axis is vertical for an HStack, horizontal for a VStack.
        horizontal ? alignment.yOffset(child: child, in: container) : alignment.xOffset(child: child, in: container)
    }

    // MARK: helpers

    private func clamp(_ value: Double?, _ lo: Double?, _ hi: Double?) -> Double? {
        guard var v = value else { return nil }
        if let hi { v = Swift.min(v, hi) }
        if let lo { v = Swift.max(v, lo) }
        return v
    }

    private func resolveAxis(fixed: Double?, min: Double?, max: Double?, proposal: Double?, content: Double) -> Double {
        if let fixed { return fixed }
        guard min != nil || max != nil else { return content }
        var v = proposal ?? content  // a flexible frame takes the offered space, else hugs its content
        if let max { v = Swift.min(v, max) }
        if let min { v = Swift.max(v, min) }
        return v
    }
}

extension CGRect {
    func inset(by insets: EdgeInsets) -> CGRect {
        CGRect(x: minX + CGFloat(insets.leading), y: minY + CGFloat(insets.top),
               width: Swift.max(0, width - CGFloat(insets.horizontal)),
               height: Swift.max(0, height - CGFloat(insets.vertical)))
    }
}
