import Foundation
import XCTest

/// Shared bounded-poll helper for asynchronous test conditions.
///
/// Replaces the ad-hoc `for _ in 0..<N where <condition> { try await Task.sleep(...) }`
/// pattern so every call site uses the same timeout semantics and produces the
/// same failure message on miss. Non-throwing: transient sleep failures are
/// swallowed and only a genuine timeout produces an `XCTFail`.
///
/// The condition closure is evaluated on `@MainActor` so callers can read
/// UI-facing state (`@Published` properties, stores, view models) directly.
/// Non-MainActor state should still be readable thanks to `@unchecked Sendable`
/// test doubles in this target.
@discardableResult
func waitUntil(
    timeoutSeconds: TimeInterval = 0.5,
    description: String = "condition",
    pollInterval: Duration = .milliseconds(20),
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await MainActor.run(body: condition) {
            return true
        }
        try? await Task.sleep(for: pollInterval)
    }
    if await MainActor.run(body: condition) {
        return true
    }
    XCTFail("Timed out waiting for \(description)", file: file, line: line)
    return false
}
