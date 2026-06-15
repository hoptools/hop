// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(AppKit)
import Dispatch
import HopUI

// Run-loop executor for AppKit: posts Swift Concurrency jobs onto the main dispatch queue (which the
// Cocoa run loop drains). AppKit doesn't strictly need a custom executor — a `Task { @MainActor in }`
// already works there — but installing one keeps `hopTask` uniform across all backends (its body runs
// on the main thread everywhere, not on a background global-executor thread).

private nonisolated func appKitScheduleOnLoop(_ work: @escaping @Sendable () -> Void) {
    DispatchQueue.main.async { work() }
}

/// Install the AppKit run-loop executor so `hopTask` runs on the main thread. Call once at startup.
public func installAppKitMainExecutor() {
    HopConcurrency.loopExecutor = HopLoopExecutor(schedule: appKitScheduleOnLoop)
}
#endif
