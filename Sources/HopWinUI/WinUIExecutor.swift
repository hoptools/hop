// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import CWinUI
import HopUI

// Custom run-loop executor for WinUI: posts Swift Concurrency jobs onto the XAML DispatcherQueue via the
// CWinUI shim (`hopwinui_schedule_on_main`). Installed by the toolkit so `hopTask { … }` / `await`
// continuations run on the UI thread — uniform with GTK4/Qt.

/// Holds a `@Sendable` closure so it can cross from a background `enqueue` into the UI-thread callback.
private nonisolated final class WinUIWorkBox {
    let work: @Sendable () -> Void
    init(_ work: @escaping @Sendable () -> Void) { self.work = work }
}

private nonisolated(unsafe) let winUIRunWork: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
    guard let userData else { return }
    Unmanaged<WinUIWorkBox>.fromOpaque(userData).takeRetainedValue().work()
}

/// Schedules `work` on the XAML DispatcherQueue. Thread-safe — `TryEnqueue` posts to the UI thread.
private nonisolated func winUIScheduleOnLoop(_ work: @escaping @Sendable () -> Void) {
    hopwinui_schedule_on_main(winUIRunWork, Unmanaged.passRetained(WinUIWorkBox(work)).toOpaque())
}

/// Install the WinUI run-loop executor so `hopTask` runs on the UI thread. Call once after `hopwinui_run`
/// has created the dispatcher (the toolkit calls this from `run`, inside the on-ready callback).
public func installWinUIMainExecutor() {
    HopConcurrency.loopExecutor = HopLoopExecutor(schedule: winUIScheduleOnLoop)
}
