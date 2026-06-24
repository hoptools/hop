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
        case .grid(let config): return .grid(config)
        case .gridRow(let va):
            // A stray GridRow outside a Grid degrades to a plain HStack. Inside a Grid it is never placed
            // through this path — the grid frames it directly and positions its cells (see placeCore(.grid)).
            return .stack(axis: .horizontal, spacing: nil,
                          alignment: Alignment(horizontal: .center, vertical: va ?? .center))
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
        case .grid(let config):
            // Content-driven column widths / row heights — but if the grid has flexible columns/rows it
            // grows to fill the offered space (like SwiftUI, where a `Divider` spreads the grid to its
            // container). An outer `.frame` still constrains it through the modifier chain.
            let m = gridMetrics(node, config: config)
            var size = m.total
            if let pw = proposal.width, m.flexibleColumns.contains(true) { size.width = Swift.max(size.width, CGFloat(pw)) }
            if let ph = proposal.height, m.flexibleRows.contains(true) { size.height = Swift.max(size.height, CGFloat(ph)) }
            return size
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
        case .grid(let config):
            gridPlaceLayout(node, config: config, available: local.size)
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

    // MARK: grid algorithm (non-lazy, column-aligned)

    /// One materialized cell within a grid line: its node, the column it starts at (running sum of prior
    /// spans in the line), and how many columns it spans.
    private struct GridCell {
        let node: RenderNode
        let firstColumn: Int
        let span: Int
    }

    /// One band of the grid: a `GridRow`'s cells, or a single loose full-span child.
    private struct GridLine {
        /// The `GridRow` container node (nil for a loose child placed directly in the grid).
        let rowNode: RenderNode?
        /// `GridRow(alignment:)` vertical guide (nil → grid default).
        let verticalAlignment: VerticalAlignment?
        let cells: [GridCell]
        let isLoose: Bool
    }

    /// The computed geometry of a grid: per-column widths, per-column H-alignment overrides, per-line
    /// heights, the partitioned lines (with measured cell sizes), which columns/rows are flexible (absorb
    /// surplus when the grid is offered more than its content size), and the overall content size.
    private struct GridMetrics {
        var lines: [GridLine]
        var columnWidths: [CGFloat]
        var columnAlignments: [HorizontalAlignment?]
        var rowHeights: [CGFloat]
        /// A column is flexible if a cell spanning it (or a loose child) is horizontally greedy.
        var flexibleColumns: [Bool]
        /// A line is flexible if any of its cells is vertically greedy.
        var flexibleRows: [Bool]
        /// Measured intrinsic size of each cell, indexed `[lineIndex][cellIndex]`.
        var measured: [[CGSize]]
        var total: CGSize
    }

    /// Whether a grid cell grows to fill space offered along `axis` — so the column/row it occupies should
    /// absorb the grid's surplus (matching SwiftUI, where e.g. a `Divider`, an un-framed shape, or a shape
    /// with `.frame(height:)` spreads the grid to fill its container). Treats shapes/dividers as greedy
    /// (their `.leaf` role hides it) and recurses through transparent containers.
    private func cellFlexible(_ node: RenderNode, _ axis: Axis) -> Bool {
        for modifier in node.layout.modifiers.reversed() {  // outermost first
            if case .frame(let f) = modifier {
                let fixed = axis == .horizontal ? f.width : f.height
                let minValue = axis == .horizontal ? f.minWidth : f.minHeight
                let maxValue = axis == .horizontal ? f.maxWidth : f.maxHeight
                // A frame that doesn't touch THIS axis (e.g. `.frame(height:)` viewed on the width axis) is
                // transparent here — keep looking inward so the content's own greediness still counts.
                if fixed == nil, minValue == nil, maxValue == nil { continue }
                if fixed != nil { return false }    // a fixed size on this axis is rigid
                return maxValue == .infinity         // fills only with an explicit max-infinity on this axis
            }
        }
        switch node.component.role {
        case .fill, .scroll, .geometry: return true
        case .leaf:
            // Shapes and dividers fill the space they're handed even though their role is `.leaf`.
            return node.component.widgetKey == .shape || node.component.widgetKey == .separator
        case .stack, .zstack:
            return node.children.contains { cellFlexible($0, axis) }
        default:
            return false
        }
    }

    /// Pass 1 of the grid layout: partition children into lines, measure every cell at its intrinsic size,
    /// and derive column widths / row heights. Loose children don't contribute to column widths (they span
    /// the full grid) but their height sets their line's height.
    private func gridMetrics(_ node: RenderNode, config: GridConfig) -> GridMetrics {
        let hSpacing = CGFloat(config.horizontalSpacing ?? hopDefaultSpacing)
        let vSpacing = CGFloat(config.verticalSpacing ?? hopDefaultSpacing)

        // A column span can never legitimately exceed the total number of cells in the grid (a span past
        // that only invents empty columns no content can fill). Clamping the effective span to this ceiling
        // matches SwiftUI (spanning beyond the available columns has no effect) AND bounds every downstream
        // sum/allocation, so a pathological `.gridCellColumns(.max)` can't overflow `col += span` or balloon
        // the column arrays.
        var totalCells = 0
        for child in node.children {
            if case .gridRow = child.component.role { totalCells += child.children.count } else { totalCells += 1 }
        }
        let spanCeiling = Swift.max(1, totalCells)
        func clampedSpan(_ raw: Int?) -> Int { Swift.max(1, Swift.min(raw ?? 1, spanCeiling)) }

        // Partition into lines, assigning each cell its starting column by cumulative span.
        var lines: [GridLine] = []
        for child in node.children {
            if case .gridRow(let va) = child.component.role {
                var cells: [GridCell] = []
                var col = 0
                for cell in child.children {
                    let span = clampedSpan(cell.gridCellColumns)
                    cells.append(GridCell(node: cell, firstColumn: col, span: span))
                    col += span
                }
                lines.append(GridLine(rowNode: child, verticalAlignment: va, cells: cells, isLoose: false))
            } else {
                lines.append(GridLine(rowNode: nil, verticalAlignment: nil,
                                      cells: [GridCell(node: child, firstColumn: 0, span: clampedSpan(child.gridCellColumns))],
                                      isLoose: true))
            }
        }

        // columnCount = max over GridRow lines of (Σ spans), capped at the cell ceiling (never more columns
        // than cells). Loose lines don't define columns.
        var columnCount = 0
        for line in lines where !line.isLoose {
            columnCount = Swift.max(columnCount, line.cells.reduce(0) { $0 + $1.span })
        }
        columnCount = Swift.min(Swift.max(columnCount, 1), spanCeiling)

        // Measure every cell at its intrinsic size (unconstrained proposal). Sanitize non-finite results
        // (e.g. a degenerate `.frame(width: .infinity)` cell) to 0 so they can't poison the column math
        // into infinite/NaN frames.
        func finite(_ v: CGFloat) -> CGFloat { v.isFinite ? v : 0 }
        var measured: [[CGSize]] = []
        for line in lines {
            measured.append(line.cells.map { cell in
                let s = size(cell.node, .unspecified)
                return CGSize(width: finite(s.width), height: finite(s.height))
            })
        }

        // Column widths: a non-spanning (span==1) cell sets the floor for its column.
        var columnWidths = [CGFloat](repeating: 0, count: columnCount)
        for (li, line) in lines.enumerated() where !line.isLoose {
            for (ci, cell) in line.cells.enumerated() where cell.span == 1 && cell.firstColumn < columnCount {
                columnWidths[cell.firstColumn] = Swift.max(columnWidths[cell.firstColumn], measured[li][ci].width)
            }
        }
        // Spanning cells do NOT widen already-populated columns (SwiftUI sizes a column by the widest
        // *non-spanning* cell in it). A spanning cell only reserves a floor for the columns it covers that
        // are still EMPTY, splitting its deficit across those; if every spanned column is already populated
        // it contributes nothing (its content is laid out within the combined width). Done in one pass over
        // each span's column range (no intermediate arrays).
        for (li, line) in lines.enumerated() where !line.isLoose {
            for (ci, cell) in line.cells.enumerated() where cell.span > 1 {
                let lastCol = Swift.min(cell.firstColumn + cell.span - 1, columnCount - 1)
                guard cell.firstColumn <= lastCol else { continue }
                var existing = CGFloat(lastCol - cell.firstColumn) * hSpacing  // inter-column spacing
                var emptyCount = 0
                for c in cell.firstColumn ... lastCol {
                    existing += columnWidths[c]
                    if columnWidths[c] == 0 { emptyCount += 1 }
                }
                let deficit = measured[li][ci].width - existing
                guard deficit > 0, emptyCount > 0 else { continue }
                let per = deficit / CGFloat(emptyCount)
                for c in cell.firstColumn ... lastCol where columnWidths[c] == 0 { columnWidths[c] += per }
            }
        }

        // Per-column horizontal alignment overrides, from any span==1 cell declaring `.gridColumnAlignment`.
        var columnAlignments = [HorizontalAlignment?](repeating: nil, count: columnCount)
        for line in lines where !line.isLoose {
            for cell in line.cells where cell.span == 1 && cell.firstColumn < columnCount {
                if let a = cell.node.gridColumnAlignment { columnAlignments[cell.firstColumn] = a }
            }
        }

        // Row heights: the tallest cell in each line (loose child included).
        var rowHeights = [CGFloat](repeating: 0, count: lines.count)
        for (li, _) in lines.enumerated() {
            rowHeights[li] = measured[li].map(\.height).max() ?? 0
        }

        // Flexible columns/rows: which absorb the grid's surplus when it's offered more than its content.
        var flexibleColumns = [Bool](repeating: false, count: columnCount)
        var flexibleRows = [Bool](repeating: false, count: lines.count)
        for (li, line) in lines.enumerated() {
            if line.isLoose {
                // A loose flexible child spans the full width → makes every column flexible.
                if cellFlexible(line.cells[0].node, .horizontal) {
                    for c in 0 ..< columnCount { flexibleColumns[c] = true }
                }
                if cellFlexible(line.cells[0].node, .vertical) { flexibleRows[li] = true }
            } else {
                for cell in line.cells {
                    if cellFlexible(cell.node, .horizontal) {
                        let last = Swift.min(cell.firstColumn + cell.span - 1, columnCount - 1)
                        if cell.firstColumn <= last { for c in cell.firstColumn ... last { flexibleColumns[c] = true } }
                    }
                    if cellFlexible(cell.node, .vertical) { flexibleRows[li] = true }
                }
            }
        }

        let totalWidth = columnWidths.reduce(0, +) + CGFloat(Swift.max(0, columnCount - 1)) * hSpacing
        let totalHeight = rowHeights.reduce(0, +) + CGFloat(Swift.max(0, lines.count - 1)) * vSpacing
        return GridMetrics(lines: lines, columnWidths: columnWidths, columnAlignments: columnAlignments,
                           rowHeights: rowHeights, flexibleColumns: flexibleColumns, flexibleRows: flexibleRows,
                           measured: measured,
                           total: CGSize(width: totalWidth, height: totalHeight))
    }

    /// Pass 2 of the grid layout: frame each `GridRow` and place every cell within its (column × row) rect.
    /// `available` is the grid's final content size; any surplus over the intrinsic content size is spread
    /// equally across the flexible columns/rows so the grid fills the space it was given.
    private func gridPlaceLayout(_ node: RenderNode, config: GridConfig, available: CGSize) {
        let m = gridMetrics(node, config: config)
        let hSpacing = CGFloat(config.horizontalSpacing ?? hopDefaultSpacing)
        let vSpacing = CGFloat(config.verticalSpacing ?? hopDefaultSpacing)
        let columnCount = m.columnWidths.count

        // Distribute horizontal/vertical surplus equally across the flexible columns/rows.
        var columnWidths = m.columnWidths
        var rowHeights = m.rowHeights
        let flexCols = (0 ..< columnCount).filter { m.flexibleColumns[$0] }
        if !flexCols.isEmpty, available.width > m.total.width {
            let extra = (available.width - m.total.width) / CGFloat(flexCols.count)
            for c in flexCols { columnWidths[c] += extra }
        }
        let flexRows = (0 ..< m.rowHeights.count).filter { m.flexibleRows[$0] }
        if !flexRows.isEmpty, available.height > m.total.height {
            let extra = (available.height - m.total.height) / CGFloat(flexRows.count)
            for r in flexRows { rowHeights[r] += extra }
        }

        // Running X offset of each column.
        var colX = [CGFloat](repeating: 0, count: columnCount)
        var x: CGFloat = 0
        for c in 0 ..< columnCount { colX[c] = x; x += columnWidths[c] + hSpacing }
        let totalWidth = columnWidths.reduce(0, +) + CGFloat(Swift.max(0, columnCount - 1)) * hSpacing

        var rowY: CGFloat = 0
        for (li, line) in m.lines.enumerated() {
            let rowH = rowHeights[li]
            if let rowNode = line.rowNode {
                // Frame the GridRow in grid-local coords; place its cells relative to the row origin.
                setFrame(rowNode, CGRect(x: 0, y: rowY, width: totalWidth, height: rowH))
                for cell in line.cells {
                    let cellRect = gridCellRect(cell, colX: colX, columnWidths: columnWidths,
                                                hSpacing: hSpacing, rowHeight: rowH)
                    let hAlign = (cell.firstColumn < columnCount ? m.columnAlignments[cell.firstColumn] : nil)
                        ?? config.alignment.horizontal
                    let vAlign = line.verticalAlignment ?? config.alignment.vertical
                    placeGridCell(cell.node, in: cellRect, hAlign: hAlign, vAlign: vAlign)
                }
            } else {
                // A loose child spans the full grid width as its own line.
                let cellRect = CGRect(x: 0, y: rowY, width: totalWidth, height: rowH)
                placeGridCell(line.cells[0].node, in: cellRect,
                              hAlign: config.alignment.horizontal, vAlign: config.alignment.vertical)
            }
            rowY += rowH + vSpacing
        }
    }

    /// The rect a cell occupies within its row (row-local coords): X/width span its columns, height = row.
    private func gridCellRect(_ cell: GridCell, colX: [CGFloat], columnWidths: [CGFloat],
                              hSpacing: CGFloat, rowHeight: CGFloat) -> CGRect {
        let count = columnWidths.count
        let firstCol = Swift.min(cell.firstColumn, count - 1)
        let lastCol = Swift.min(cell.firstColumn + cell.span - 1, count - 1)
        var width: CGFloat = 0
        for c in firstCol ... lastCol { width += columnWidths[c] }
        width += CGFloat(lastCol - firstCol) * hSpacing
        return CGRect(x: colX[firstCol], y: 0, width: width, height: rowHeight)
    }

    /// Place one cell within `cellRect`: propose it the cell size (except on `gridCellUnsizedAxes`, where it
    /// keeps its intrinsic extent), then align its chosen size within the cell — `gridCellAnchor` overrides
    /// the column/row alignment guides when present.
    private func placeGridCell(_ cell: RenderNode, in cellRect: CGRect,
                               hAlign: HorizontalAlignment, vAlign: VerticalAlignment) {
        let unsized = cell.gridCellUnsizedAxes ?? []
        let proposal = ProposedViewSize(
            width: unsized.contains(.horizontal) ? nil : Double(cellRect.width),
            height: unsized.contains(.vertical) ? nil : Double(cellRect.height))
        let chosen = size(cell, proposal)
        let ox: CGFloat
        let oy: CGFloat
        if let anchor = cell.gridCellAnchor {
            ox = (cellRect.width - chosen.width) * anchor.x
            oy = (cellRect.height - chosen.height) * anchor.y
        } else {
            let alignment = Alignment(horizontal: hAlign, vertical: vAlign)
            ox = alignment.xOffset(child: chosen.width, in: cellRect.width)
            oy = alignment.yOffset(child: chosen.height, in: cellRect.height)
        }
        place(cell, CGRect(x: cellRect.minX + ox, y: cellRect.minY + oy, width: chosen.width, height: chosen.height))
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
        case .scroll, .geometry, .lazyStack, .grid:
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
    /// distributed space rather than its ideal extent). The OUTERMOST `.frame` that constrains this axis
    /// decides (fixed → rigid; `max…: .infinity` → fills); a frame that doesn't touch this axis at all is
    /// transparent here, so we keep looking inward. Otherwise a Spacer / ScrollView / GeometryReader / shape
    /// fills (a shape fills the space it's handed), and a transparent stack/zstack fills if any child does.
    /// Kept in lockstep with `cellFlexible` (the grid analogue) EXCEPT: a `Spacer` is greedy only here
    /// (stacks distribute leftover to spacers), and a `Divider`/`.separator` is NOT greedy along a stack's
    /// main axis — it stays thin there and fills its cross axis via measurement (a grid's *loose* divider is
    /// the different full-span case, which `cellFlexible` does treat as greedy).
    private func greedyAlong(_ node: RenderNode, _ axis: Axis) -> Bool {
        for modifier in node.layout.modifiers.reversed() {  // outermost first
            if case .frame(let f) = modifier {
                let fixed = axis == .vertical ? f.height : f.width
                let minValue = axis == .vertical ? f.minHeight : f.minWidth
                let maxValue = axis == .vertical ? f.maxHeight : f.maxWidth
                if fixed == nil, minValue == nil, maxValue == nil { continue }  // doesn't touch this axis
                if fixed != nil { return false }       // a fixed size is rigid
                return maxValue == .infinity            // fills only with an explicit max-infinity
            }
        }
        switch node.component.role {
        case .fill, .spacer, .scroll, .geometry: return true
        case .leaf: return node.component.widgetKey == .shape  // shapes fill; a Divider stays thin on the main axis
        case .stack, .zstack: return node.children.contains { greedyAlong($0, axis) }
        default: return false
        }
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
