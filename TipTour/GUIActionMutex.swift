// TipTour/GUIActionMutex.swift
// Moved from TipTour/Agents/Core/ during rebrand strip.

import Foundation

/// Process-wide FIFO lock for synthetic GUI input (mouse clicks, key
/// presses, paste-typing). macOS exposes exactly one cursor, one
/// keyboard focus, and one frontmost-app slot — so when multiple
/// callers post CGEvents simultaneously they interleave at the HID
/// layer and produce phantom clicks, partial keystrokes, or paste
/// content that lands in the wrong app.
///
/// Every entry point in `ActionExecutor` (`click`, `pressKeyboardShortcut`,
/// `typeText`) runs inside `runExclusive` so:
///
///   1. The voice-mode `WorkflowRunner` and background `TaskAgent`s
///      share the cursor cleanly without trampling each other.
///   2. Each caller's action sequence (move → down → up, or paste-typing's
///      multi-step Cmd+V + clipboard restore) runs atomically — no other
///      caller can squeeze a click between the down and the up.
///
/// FIFO ordering: callers acquire in arrival order, so a clock queued
/// first lands first. We deliberately avoid priority/cancellation
/// semantics here — the lock is a fairness guarantee, not a scheduler.
actor GUIActionMutex {

    static let shared = GUIActionMutex()

    private var isHeld: Bool = false
    private var queuedContinuations: [CheckedContinuation<Void, Never>] = []

    /// Acquires the lock, runs `operation`, then releases — even if
    /// `operation` throws. The closure is invoked from whatever
    /// isolation context the caller is on (it is NOT bounced onto the
    /// mutex's actor), so `@MainActor` callers stay on the main actor
    /// throughout their CGEvent posting.
    static func runExclusive<T: Sendable>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await shared.acquire()
        do {
            let result = try await operation()
            await shared.release()
            return result
        } catch {
            await shared.release()
            throw error
        }
    }

    /// Number of callers currently waiting behind the holder. Useful
    /// for diagnostics ("Action queued behind 2 other agents") and
    /// tests. Always 0 when the lock is free.
    var queueDepth: Int { queuedContinuations.count }

    /// Whether the lock is currently held by some caller.
    var locked: Bool { isHeld }

    // MARK: - Private

    private func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            queuedContinuations.append(continuation)
        }
    }

    private func release() {
        if let nextWaiter = queuedContinuations.first {
            queuedContinuations.removeFirst()
            nextWaiter.resume()
            // isHeld stays true — the next waiter now owns the lock.
        } else {
            isHeld = false
        }
    }
}
