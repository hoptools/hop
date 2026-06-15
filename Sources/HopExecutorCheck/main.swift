// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// Headless verification that the GTK4 custom run-loop executor actually routes Swift Concurrency onto
// GLib's loop: installs the executor, runs a bare GMainLoop (no GTK window / display), starts async work
// under that executor that awaits a background sleep and then mutates state, and confirms it ran on the
// loop. Prints EXECUTOR_OK / EXECUTOR_FAIL and exits 0 / 1. Run: `swift run hop-executor-check`.

import Foundation  // exit
import CGTK4
import HopUI
import HopGTK4

installGTK4MainExecutor()  // sets HopConcurrency.loopExecutor to the GLib run-loop executor

/// Shared, mutable state crossing the background sleep continuation back onto the loop.
final class Ctx: @unchecked Sendable {
    var ran = false
    let loop: UnsafeMutableRawPointer
    init(_ loop: UnsafeMutableRawPointer) { self.loop = loop }
}

let ctx = Ctx(hop_main_loop_new()!)

// Async work via the real `hopTask` API. Both its body and the post-sleep continuation must run on the
// GLib loop (not libdispatch's main queue, which g_main_loop_run never drains).
MainActor.assumeIsolated {
    hopTask {
        try? await Task.sleep(nanoseconds: 30_000_000)  // resumes via background timer → run-loop executor
        ctx.ran = true
        hop_main_loop_quit(ctx.loop)
    }
}

// Safety net: quit after 3s regardless, so a broken executor fails (doesn't hang).
let timeout: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { loopPtr in
    if let loopPtr { hop_main_loop_quit(loopPtr) }
    return 0  // G_SOURCE_REMOVE
}
hop_timeout_add(3000, timeout, ctx.loop)

hop_main_loop_run(ctx.loop)
hop_main_loop_unref(ctx.loop)

print(ctx.ran ? "EXECUTOR_OK" : "EXECUTOR_FAIL")
exit(ctx.ran ? 0 : 1)
