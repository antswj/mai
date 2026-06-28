import Foundation

// A rolling buffer of the last N turns and M seconds. The classifier reads this
// whole window, not just the latest line, so it can catch cross-turn references
// (for example "your turn" that refers to a question asked two turns earlier).
public struct RollingContext: Sendable {
    public struct Turn: Sendable {
        public let speaker: String?
        public let text: String
        public let timestamp: Date
    }

    private var turns: [Turn] = []
    private let maxTurns: Int
    private let maxSeconds: Double

    public init(maxTurns: Int, maxSeconds: Double) {
        self.maxTurns = maxTurns
        self.maxSeconds = maxSeconds
    }

    public mutating func append(_ event: TranscriptEvent) {
        turns.append(Turn(speaker: event.speaker, text: event.text, timestamp: event.timestamp))
        prune(now: event.timestamp)
    }

    private mutating func prune(now: Date) {
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
        let cutoff = now.addingTimeInterval(-maxSeconds)
        turns.removeAll { $0.timestamp < cutoff }
    }

    /// The window rendered as labeled lines, oldest first, for the classifier.
    public func window() -> String {
        turns.map { t in
            let who = t.speaker?.isEmpty == false ? t.speaker! : "Speaker"
            return "\(who): \(t.text)"
        }.joined(separator: "\n")
    }

    public var latest: Turn? { turns.last }
    public var count: Int { turns.count }
    public func allText() -> String { window() }
}
