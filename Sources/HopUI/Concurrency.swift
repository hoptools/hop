// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Swift Concurrency integration with the toolkit's run loop.
//
// Swift's default executors schedule onto libdispatch. A GLib (GTK4) or Qt event loop never drains
// libdispatch's main queue, so a plain `Task { @MainActor in … }` would hang there. The formal
// `ExecutorFactory`/`MainExecutor` API for replacing the main-actor executor isn't shipped in Swift
// 6.3.2 (and the legacy `swift_task_enqueueMainExecutor_hook` is no longer consulted by the runtime),
// but custom `TaskExecutor`s (SE-0417) ARE supported. So each toolkit provides a `HopLoopExecutor`
// whose `enqueue` runs jobs on its loop, and `hopTask` runs async work under that executor preference —
// uniform across GTK4, Qt, and AppKit.

/// A custom `TaskExecutor` that runs jobs on a toolkit's native run loop. The toolkit supplies a
/// thread-safe `schedule` primitive (GLib `g_idle_add`, Qt queued invocation, or `DispatchQueue.main`)
/// that posts work to the loop's thread; `enqueue` may be called from a background thread (e.g. a
/// `Task.sleep` continuation), so `schedule` must be safe to call from anywhere.
public nonisolated final class HopLoopExecutor: TaskExecutor, @unchecked Sendable {
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void

    public init(schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.schedule = schedule
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let runner = JobRunner(UnownedJob(job), asUnownedTaskExecutor())
        schedule { runner.run() }
    }

    /// Carries the (non-Sendable) job + executor across the thread hop into the loop. Safe because the
    /// runtime keeps the job alive until it runs, and we only ever run it once, on the loop thread.
    private struct JobRunner: @unchecked Sendable {
        let job: UnownedJob
        let executor: UnownedTaskExecutor
        init(_ job: UnownedJob, _ executor: UnownedTaskExecutor) { self.job = job; self.executor = executor }
        func run() { job.runSynchronously(on: executor) }
    }
}

/// The toolkit's run-loop executor for Swift Concurrency, installed by the runtime when the app starts.
@MainActor
public enum HopConcurrency {
    public static var loopExecutor: HopLoopExecutor?
}

/// Starts async work that runs on the toolkit's run loop, so `await`/`Task.sleep` continuations resume
/// there (not on libdispatch's main queue, which GLib/Qt loops never drain). Mirrors a plain `Task {}`
/// for app code, but loop-correct on every toolkit. Mutate `@Observable` model state from inside; the
/// resulting re-render is coalesced onto the same loop.
@MainActor
@discardableResult
public func hopTask(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    if let executor = HopConcurrency.loopExecutor {
        // `executorPreference` runs the task on the loop executor from the start; a plain `Task {}` would
        // inherit the caller's @MainActor isolation and stall on the (undrained) dispatch main queue.
        return Task(executorPreference: executor) { await body() }
    }
    return Task { await body() }
}
