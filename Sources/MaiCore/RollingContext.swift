import Foundation

// A rolling buffer of the last N turns and M seconds. The classifier reads this
// whole window, not just the latest line, so it can catch cross-turn references
// (for example "your turn" that refers to a question asked two turns earlier).
public struct RollingContext: Sendable {
    public struct Turn: Sendable {
        public let speaker: String?
        public let text: String
        public let timestamp: Date
        public let language: String?
        public let source: SpeakerSource?
    }

    private var turns: [Turn] = []
    private let maxTurns: Int
    private let maxSeconds: Double

    public init(maxTurns: Int, maxSeconds: Double) {
        self.maxTurns = maxTurns
        self.maxSeconds = maxSeconds
    }

    public mutating func append(_ event: TranscriptEvent) {
        turns.append(Turn(speaker: event.speaker, text: event.text, timestamp: event.timestamp,
                          language: event.language, source: event.source ?? event.vocalSignal?.source))
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
        renderedTurns().joined(separator: "\n")
    }

    /// `tagged` adds a per-line "(who, language)" marker for the coach, which otherwise
    /// has to infer both from the script. The UNTAGGED form is the classifier's input and
    /// must stay byte-identical: the deterministic stub parses it by splitting on the
    /// first colon, so a tag in the default form would corrupt every classifier fixture.
    public func window(maxChars: Int, tagged: Bool = false) -> String {
        let rendered = renderedTurns(tagged: tagged)
        let full = rendered.joined(separator: "\n")
        guard maxChars > 0 else { return "" }
        guard full.count > maxChars else { return full }
        let widestPrefix = Self.omissionPrefix(dropped: rendered.count)
        let lineBudget = max(0, maxChars - widestPrefix.count - 1)
        guard lineBudget > 0 else { return String(widestPrefix.prefix(maxChars)) }

        var kept: [String] = []
        var used = 0
        for line in rendered.reversed() {
            let extra = line.count + (kept.isEmpty ? 0 : 1)
            if used + extra <= lineBudget {
                kept.insert(line, at: 0)
                used += extra
            } else if kept.isEmpty {
                kept = [String(line.suffix(lineBudget))]
                break
            } else {
                break
            }
        }
        let dropped = max(0, rendered.count - kept.count)
        let prefixed = ([Self.omissionPrefix(dropped: dropped)] + kept).joined(separator: "\n")
        return prefixed.count <= maxChars ? prefixed : String(prefixed.prefix(maxChars))
    }

    private func renderedTurns(tagged: Bool = false) -> [String] {
        turns.map { t in
            let who = t.speaker?.isEmpty == false ? t.speaker! : "Speaker"
            guard tagged else { return "\(who): \(t.text)" }
            var marks: [String] = []
            if let s = t.source { marks.append(s == .user ? "you" : "other") }
            if let l = t.language, !l.isEmpty { marks.append(l) }
            let tag = marks.isEmpty ? "" : " (\(marks.joined(separator: ", ")))"
            return "\(who)\(tag): \(t.text)"
        }
    }

    private static func omissionPrefix(dropped: Int) -> String {
        "[\(dropped) earlier lines omitted to fit context]"
    }

    public var latest: Turn? { turns.last }
    public var count: Int { turns.count }
    public func allText() -> String { window() }
}
