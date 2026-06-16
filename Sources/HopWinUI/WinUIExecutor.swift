// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Dispatch
import HopUI

// Run-loop executor for WinUI. The Windows App SDK's XAML `Application.start` runs a classic Win32
// message loop on the main thread, and swift-winui installs a `MainRunLoopTickler` that drains
// `RunLoop.main` (and, with it, the main libdispatch queue) inside that loop. So — unlike GTK4/Qt, whose
// native loops never drain libdispatch — posting to `DispatchQueue.main` reaches the UI thread here, the
// same way it does under AppKit's Cocoa loop. Installing a `HopLoopExecutor` over it keeps `hopTask`
// uniform across every toolkit (its body and `await` continuations resume on the UI thread, not on a
// background global-executor thread), so an `@Observable` mutation from an async task re-renders on-loop.

private nonisolated func winUIScheduleOnLoop(_ work: @escaping @Sendable () -> Void) {
    DispatchQueue.main.async { work() }
}

/// Install the WinUI run-loop executor so `hopTask` runs on the UI thread. Call once, after the XAML
/// `Application` exists (the toolkit calls this from `run`).
public func installWinUIMainExecutor() {
    HopConcurrency.loopExecutor = HopLoopExecutor(schedule: winUIScheduleOnLoop)
}
