// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// A progress indicator, mirroring SwiftUI's `ProgressView`. Determinate when given a `value` (shown as
// a fraction of `total`); indeterminate (animated) otherwise. Maps to NSProgressIndicator /
// GtkProgressBar / QProgressBar.

public struct ProgressView: View, PrimitiveView {
    let value: Double?
    let total: Double
    let label: String?

    /// An indeterminate progress indicator.
    public init() {
        value = nil
        total = 1
        label = nil
    }

    /// A determinate progress indicator showing `value` out of `total` (indeterminate if `value` is nil).
    public init(value: Double?, total: Double = 1) {
        self.value = value
        self.total = total
        self.label = nil
    }

    /// A labeled determinate progress indicator. Mirrors `ProgressView(_:value:total:)`.
    public init<S: StringProtocol>(_ label: S, value: Double?, total: Double = 1) {
        self.label = String(label)
        self.value = value
        self.total = total
    }

    public typealias Body = Never
    public var body: Never { fatalError("ProgressView has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var patch = WidgetPatch()
        // nil → indeterminate; otherwise the clamped fraction of `total`.
        if let value, total > 0 {
            patch.progressValue = Swift.max(0, Swift.min(1, value / total))
        }
        if let label { patch.accessibilityLabel = label }
        return RenderNode(id: context.id, kind: .progress,
                          component: PrimitiveLeafComponent(WidgetKey("progress"), patch: patch))
    }
}
