import Foundation

public struct TimeoutError: Error, CustomStringConvertible {
    public let seconds: Double
    public var description: String { "timed out after \(seconds)s" }
}

// Run `operation` with a hard ceiling. If the deadline wins, the operation task is
// cancelled (cooperative: the async URLSession calls it wraps abort in flight) and
// TimeoutError is thrown. This is the guard on every network enrichment so a slow
// or hung lookup can never stall a card past its latency cap.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw TimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        // The first task to finish wins; cancelAll (via defer) stops the loser.
        guard let result = try await group.next() else { throw TimeoutError(seconds: seconds) }
        return result
    }
}

// Convenience: returns nil instead of throwing on timeout/failure, for enrichment
// parts that must always resolve to a terminal state (a value or "no result").
public func withTimeoutOrNil<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async -> T? {
    do { return try await withTimeout(seconds: seconds, operation) }
    catch { return nil }
}
