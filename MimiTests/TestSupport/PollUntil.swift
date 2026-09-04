import Foundation

/// Polls `condition` until it holds, bounded by `timeout`. Awaits between
/// polls so pending main-actor tasks (spawned teardown, callback hops, the
/// cooperative pool) make progress first — the wait ends as soon as the
/// awaited state is observable, never at a fixed delay.
///
/// Returns `false` on timeout so callers assert explicitly and the failure
/// names the expectation, not the helper.
@MainActor
@discardableResult
func pollUntil(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Off-main-actor counterpart for suites that are not `@MainActor` (e.g. the
/// CrispASR engine suites): same bounded-poll semantics, but the condition
/// runs wherever the caller is isolated, so it may read lock-guarded state
/// that must not hop to the main actor. The default timeout is larger than
/// the main-actor gate's — off-main waits cover real dispatch-queue work,
/// not near-instant observation hops.
@discardableResult
func pollUntilOffMain(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
