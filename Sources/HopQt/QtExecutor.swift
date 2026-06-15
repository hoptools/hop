// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import CQt
import HopUI

// Custom run-loop executor for Qt: posts Swift Concurrency jobs onto Qt's event loop via a thread-safe
// queued invocation (`hopqt_run_on_main`). Installed by the backend so `hopTask { … }` / `await`
// continuations run on Qt's loop.

/// Holds a `@Sendable` closure so it can cross from a background `enqueue` into the Qt main-thread call.
private nonisolated final class QtWorkBox {
    let work: @Sendable () -> Void
    init(_ work: @escaping @Sendable () -> Void) { self.work = work }
}

private nonisolated(unsafe) let qtRunWork: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
    guard let userData else { return }
    Unmanaged<QtWorkBox>.fromOpaque(userData).takeRetainedValue().work()
}

/// Schedules `work` on Qt's event loop. Thread-safe — posts a queued invocation to qApp's thread.
private nonisolated func qtScheduleOnLoop(_ work: @escaping @Sendable () -> Void) {
    hopqt_run_on_main(Unmanaged.passRetained(QtWorkBox(work)).toOpaque(), qtRunWork)
}

/// Install the Qt run-loop executor so Swift Concurrency runs on Qt's loop. Call once after the
/// QApplication exists.
public func installQtMainExecutor() {
    HopConcurrency.loopExecutor = HopLoopExecutor(schedule: qtScheduleOnLoop)
}
