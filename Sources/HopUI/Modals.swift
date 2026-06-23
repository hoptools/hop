// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Modal presentations — `.alert(_:isPresented:actions:message:)` and `.sheet(isPresented:content:)`.
// Both are PRESENTATION MODIFIERS (like `.fileImporter`/`.fileExporter`): they attach a spec to the
// modified view's node, reapplied every reconcile, and the toolkit shows/dismisses a native dialog driven
// by the `isPresented` binding (the toolkit calls `setPresented(false)` to flip it back when dismissed).
//
// Alert → a native alert dialog (NSAlert / GtkAlertDialog / QMessageBox / WinUI ContentDialog) whose
// buttons map to the actions. Sheet → a native modal window hosting a LIVE HopUI view tree: the sheet body
// is `evaluateResolved`'d here (recording its dependencies on the enclosing composite, the documented
// content-collecting pattern), so it re-renders reactively, and the toolkit mounts/updates it via a
// retained per-sheet reconciler.

// MARK: - Button role (for alert buttons)

/// A semantic role for a `Button`, mirroring SwiftUI's `ButtonRole`. Used by ``Alert`` to style the
/// cancel/destructive buttons of a native dialog; ignored for ordinary in-content buttons (for now).
public enum ButtonRole: Sendable, Equatable {
    case destructive
    case cancel
}

// MARK: - Dismiss

/// An action that dismisses the current presentation (e.g. a `.sheet`). Mirrors SwiftUI's `DismissAction`,
/// read via `@Environment(\.dismiss)` and invoked as `dismiss()`. Inside a sheet, it flips the presenting
/// binding to false. nonisolated like ``OpenWindowAction`` so it can be a default environment value.
public nonisolated struct DismissAction {
    private let handler: (@MainActor () -> Void)?
    public init() { handler = nil }
    init(handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @MainActor public func callAsFunction() { handler?() }
}

// MARK: - Alert

/// One button of an ``AlertSpec`` — its title, optional role, and action. The toolkit maps the role to the
/// native dialog's cancel/destructive treatment.
public struct AlertButton {
    public let title: String
    public let role: ButtonRole?
    public let action: @MainActor () -> Void
    public init(title: String, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.title = title; self.role = role; self.action = action
    }
}

/// Backend-agnostic payload for an `.alert` presentation, attached to the modified view's node and
/// reapplied each reconcile (not `Equatable`). The toolkit shows a native alert when `isPresented`
/// transitions true, runs the chosen button's action, then calls `setPresented(false)`.
public struct AlertSpec {
    public let isPresented: Bool
    public let title: String
    public let message: String?
    public let buttons: [AlertButton]
    public let setPresented: @MainActor (Bool) -> Void
}

// MARK: - Sheet

/// Backend-agnostic payload for a `.sheet` presentation. `content` is the already-resolved sheet body
/// subtree (nil when not presented) — re-resolved every reconcile so the sheet updates reactively. The
/// toolkit hosts it in a native modal window via a retained per-sheet reconciler, and calls
/// `setPresented(false)` (and `onDismiss`) when the window closes.
/// A reference type (not a struct) so `RenderNode.sheet` doesn't recursively contain `RenderNode` by value
/// (`content` is a `RenderNode`). Created fresh each reconcile; never compared.
public final class SheetSpec {
    public let isPresented: Bool
    public let content: RenderNode?
    public let onDismiss: (@MainActor () -> Void)?
    public let setPresented: @MainActor (Bool) -> Void
    public init(isPresented: Bool, content: RenderNode?, onDismiss: (@MainActor () -> Void)?,
                setPresented: @escaping @MainActor (Bool) -> Void) {
        self.isPresented = isPresented; self.content = content
        self.onDismiss = onDismiss; self.setPresented = setPresented
    }
}

// MARK: - Modifiers

struct _AlertModifier<Content: View, Actions: View, Message: View>: View, PrimitiveView {
    let content: Content
    let title: String
    let isPresented: Bool
    let actions: Actions
    let message: Message?
    let setPresented: @MainActor (Bool) -> Void

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        // Extract the buttons from the actions builder (each Button → a `.button` node carrying title/role/
        // action), and the message string from the message builder — only when presenting (cheap either way).
        var buttons: [AlertButton] = []
        var messageText: String? = nil
        if isPresented {
            for n in evaluateResolved(actions, context.appending(1)) where n.component.widgetKey == .button {
                buttons.append(AlertButton(title: n.effectivePatch.title ?? "",
                                           role: n.buttonRole,
                                           action: n.effectiveAction ?? {}))
            }
            if let message {
                messageText = evaluateResolved(message, context.appending(2))
                    .first?.effectivePatch.text
            }
        }
        node.alert = AlertSpec(isPresented: isPresented, title: title, message: messageText,
                               buttons: buttons, setPresented: setPresented)
        return node
    }
}

struct _SheetModifier<Content: View, SheetBody: View>: View, PrimitiveView {
    let content: Content
    let isPresented: Bool
    let sheetBody: SheetBody
    let onDismiss: (@MainActor () -> Void)?
    let setPresented: @MainActor (Bool) -> Void

    typealias Body = Never
    var body: Never { fatalError() }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first
            ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        var resolved: RenderNode? = nil
        if isPresented {
            // Resolve the sheet body within the main render pass so it stays reactive (its reads record on
            // the enclosing composite). Inject `@Environment(\.dismiss)` so the content can dismiss itself.
            let dismiss = DismissAction { setPresented(false) }  // flips the presenting binding
            let hosted = _EnvironmentWritingView(content: sheetBody) { $0.dismiss = dismiss }
            resolved = evaluateResolved(hosted, context.appending(1)).first
        }
        node.sheet = SheetSpec(isPresented: isPresented, content: resolved,
                               onDismiss: onDismiss, setPresented: setPresented)
        return node
    }
}

// MARK: - View extensions (SwiftUI-matching signatures, for dual-compile)

extension View {
    /// Presents a native alert when `isPresented` becomes true. The `actions` builder's `Button`s become the
    /// dialog buttons; the `message` builder's `Text` becomes the body. Mirrors SwiftUI's
    /// `.alert(_:isPresented:actions:message:)`.
    public func alert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>,
                                        @ViewBuilder actions: () -> A,
                                        @ViewBuilder message: () -> M) -> some View {
        _AlertModifier(content: self, title: title, isPresented: isPresented.wrappedValue,
                       actions: actions(), message: message(),
                       setPresented: { isPresented.wrappedValue = $0 })
    }

    /// Presents a native alert with no message body. Mirrors SwiftUI's `.alert(_:isPresented:actions:)`.
    public func alert<A: View>(_ title: String, isPresented: Binding<Bool>,
                               @ViewBuilder actions: () -> A) -> some View {
        _AlertModifier<Self, A, EmptyView>(content: self, title: title, isPresented: isPresented.wrappedValue,
                       actions: actions(), message: nil,
                       setPresented: { isPresented.wrappedValue = $0 })
    }

    /// Presents `content` in a native modal sheet when `isPresented` becomes true. The content is a live
    /// HopUI view tree (reactive); dismiss it by setting the binding false or via `@Environment(\.dismiss)`.
    /// Mirrors SwiftUI's `.sheet(isPresented:onDismiss:content:)`.
    public func sheet<SheetContent: View>(isPresented: Binding<Bool>,
                                          onDismiss: (@MainActor () -> Void)? = nil,
                                          @ViewBuilder content: () -> SheetContent) -> some View {
        _SheetModifier(content: self, isPresented: isPresented.wrappedValue, sheetBody: content(),
                       onDismiss: onDismiss, setPresented: { isPresented.wrappedValue = $0 })
    }
}
