// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
import AppKit
import HopUI
@testable import HopAppKit

// The reconciler re-applies gesture handlers on EVERY render (Reconciler.applyCrossCutting). These tests
// lock in the fix for that: re-applying a still-present gesture must KEEP the native recognizer alive and
// only refresh the captured closures. The old code tore the recognizer down + recreated it each render,
// which cancelled an in-flight drag/magnify/rotate (the fresh recognizer never saw the mouse-down) — that
// was why continuous value-carrying gestures appeared dead on every toolkit. (GTK4/Qt/WinUI use the same
// idempotent structure; AppKit exercises it here without needing a window.)
@MainActor @Suite struct GestureIdempotencyTests {

    private func dragSpec(_ onChanged: @escaping @MainActor (DragGesture.Value) -> Void) -> DragGestureSpec {
        guard case .drag(let s) = DragGesture().onChanged(onChanged)._attachment else { fatalError() }
        return s
    }
    private func magnifySpec(_ onChanged: @escaping @MainActor (MagnifyGesture.Value) -> Void) -> MagnifyGestureSpec {
        guard case .magnify(let s) = MagnifyGesture().onChanged(onChanged)._attachment else { fatalError() }
        return s
    }
    private func rotateSpec(_ onChanged: @escaping @MainActor (RotateGesture.Value) -> Void) -> RotateGestureSpec {
        guard case .rotate(let s) = RotateGesture().onChanged(onChanged)._attachment else { fatalError() }
        return s
    }

    @Test func dragRecognizerSurvivesReapplicationAndRefreshesClosure() {
        let toolkit = AppKitToolkit()
        let handle = AppKitWidget(NSView())

        var firstFired = 0, secondFired = 0
        toolkit.setDragHandler(handle, dragSpec { _ in firstFired += 1 })
        let recognizer = handle.panRecognizer
        let target = handle.panTarget
        #expect(recognizer != nil)
        #expect(target != nil)

        // Re-apply with a brand-new closure, as a re-render does.
        toolkit.setDragHandler(handle, dragSpec { _ in secondFired += 1 })
        #expect(handle.panRecognizer === recognizer)   // SAME recognizer — not destroyed mid-gesture
        #expect(handle.panTarget === target)

        // The target now invokes the LATEST closure, not the stale first one.
        handle.panTarget?.onChanged?(DragGesture.Value(startLocation: .zero, location: .zero, translation: .zero))
        #expect(firstFired == 0)
        #expect(secondFired == 1)

        toolkit.setDragHandler(handle, nil)   // nil tears it down
        #expect(handle.panRecognizer == nil)
        #expect(handle.panTarget == nil)
    }

    @Test func magnifyRecognizerSurvivesReapplication() {
        let toolkit = AppKitToolkit()
        let handle = AppKitWidget(NSView())
        toolkit.setMagnifyHandler(handle, magnifySpec { _ in })
        let recognizer = handle.magnifyRecognizer
        #expect(recognizer != nil)
        toolkit.setMagnifyHandler(handle, magnifySpec { _ in })
        #expect(handle.magnifyRecognizer === recognizer)
        toolkit.setMagnifyHandler(handle, nil)
        #expect(handle.magnifyRecognizer == nil)
    }

    @Test func rotateRecognizerSurvivesReapplication() {
        let toolkit = AppKitToolkit()
        let handle = AppKitWidget(NSView())
        toolkit.setRotateHandler(handle, rotateSpec { _ in })
        let recognizer = handle.rotateRecognizer
        #expect(recognizer != nil)
        toolkit.setRotateHandler(handle, rotateSpec { _ in })
        #expect(handle.rotateRecognizer === recognizer)
        toolkit.setRotateHandler(handle, nil)
        #expect(handle.rotateRecognizer == nil)
    }
}
