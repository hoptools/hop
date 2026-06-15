// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import CGTK4
import HopUI

// Custom run-loop executor for GTK4: posts Swift Concurrency jobs onto GLib's main loop via
// `g_idle_add` (thread-safe; wakes the loop; its callback runs on the main thread). Installed by the
// toolkit so `hopTask { … }` / `await` continuations run on GTK's loop, which never drains libdispatch.

/// Holds a `@Sendable` closure so it can cross from a background `enqueue` into the GLib idle callback.
private nonisolated final class GTK4WorkBox {
    let work: @Sendable () -> Void
    init(_ work: @escaping @Sendable () -> Void) { self.work = work }
}

private nonisolated(unsafe) let gtk4RunWork: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { userData in
    guard let userData else { return 0 }
    Unmanaged<GTK4WorkBox>.fromOpaque(userData).takeRetainedValue().work()
    return 0  // G_SOURCE_REMOVE
}

/// Schedules `work` on GLib's main loop. Thread-safe — `g_idle_add` may be called from any thread.
private nonisolated func gtk4ScheduleOnLoop(_ work: @escaping @Sendable () -> Void) {
    hop_idle_add(gtk4RunWork, Unmanaged.passRetained(GTK4WorkBox(work)).toOpaque())
}

/// Install the GTK4 run-loop executor so Swift Concurrency runs on GLib's loop. Call once at startup.
public func installGTK4MainExecutor() {
    HopConcurrency.loopExecutor = HopLoopExecutor(schedule: gtk4ScheduleOnLoop)
}
