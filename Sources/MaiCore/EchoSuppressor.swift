import Foundation

// Transcript-level echo suppression: the reliable, language-agnostic backstop for the
// case where a remote participant's voice plays out of the speakers, the microphone
// picks it back up, and it gets transcribed a second time as the local user ("You").
//
// When a mic ("You") utterance closely matches a system-audio utterance that arrived
// just before it, it is treated as echo and dropped. The local user's own speech has
// no matching recent system utterance, so it is kept.
//
// Two deliberate guards so genuine user speech is never dropped (the spec ranks
// never-drop-genuine above always-catch-echo):
//  - a LENGTH FLOOR: only long utterances are eligible. Short backchannels ("yeah",
//    "はい") collide between speakers all the time and a verbatim long echo is what
//    actually identifies echo, so short matches are kept even if identical.
//  - consume-once: a given system utterance can suppress at most one later mic line.
//
// Pure and deterministic (an explicit clock is passed in), so it is unit-tested with
// no audio.
public struct EchoSuppressor: Sendable {
    public struct Config: Sendable {
        public var windowSeconds: Double      // how far BACK a matching system line may be
        public var forwardSeconds: Double     // how far AFTER the mic line a system line may finalize
        public var similarity: Double         // char-bigram Jaccard threshold to call it echo
        public var minChars: Int              // length floor (normalized chars) to be eligible
        public var minWords: Int              // or this many words
        public init(windowSeconds: Double = 9, forwardSeconds: Double = 3.5, similarity: Double = 0.72,
                    minChars: Int = 12, minWords: Int = 4) {
            self.windowSeconds = windowSeconds; self.forwardSeconds = forwardSeconds
            self.similarity = similarity; self.minChars = minChars; self.minWords = minWords
        }
    }

    private let config: Config
    private struct Recent { let normalized: String; let at: Date; var used: Bool }
    private var recentSystem: [Recent] = []

    public init(config: Config = Config()) { self.config = config }

    // Record a finalized SYSTEM (remote) utterance so later mic lines can be matched.
    public mutating func noteSystem(_ text: String, at: Date) {
        let norm = Self.normalize(text)
        guard !norm.isEmpty else { return }
        recentSystem.append(Recent(normalized: norm, at: at, used: false))
        prune(now: at)
    }

    // Decide whether a finalized MIC ("You") utterance is an echo of a recent system
    // utterance and should be dropped. Marks the matched system line consumed.
    public mutating func isEcho(_ text: String, at: Date) -> Bool {
        prune(now: at)
        let norm = Self.normalize(text)
        // Length floor: short utterances are never treated as echo (a genuine "yeah"
        // must survive even if a remote "yeah" preceded it).
        guard norm.count >= config.minChars || wordCount(text) >= config.minWords else { return false }
        for i in recentSystem.indices {
            guard !recentSystem[i].used else { continue }
            // A matching system line may be up to windowSeconds before the mic line, or
            // up to forwardSeconds after it (the mic echo can finalize first, then the
            // system line finalizes during the hold).
            let delta = at.timeIntervalSince(recentSystem[i].at)   // >0: system before mic
            guard delta <= config.windowSeconds, delta >= -config.forwardSeconds else { continue }
            if Self.similarity(norm, recentSystem[i].normalized) >= config.similarity {
                recentSystem[i].used = true
                return true
            }
        }
        return false
    }

    private mutating func prune(now: Date) {
        // Keep entries long enough to match a held mic final that finalized earlier.
        recentSystem.removeAll { now.timeIntervalSince($0.at) > config.windowSeconds + config.forwardSeconds }
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    // MARK: - Pure text helpers

    // Lowercase, strip whitespace and punctuation. Works across scripts (CJK has no
    // case or spaces between words, so the comparison is on the bare character run).
    public static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) { out.append(u) }
        }
        return String(out)
    }

    // Jaccard similarity over character bigrams: |A ∩ B| / |A ∪ B|. Language-agnostic.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let ba = bigrams(a), bb = bigrams(b)
        if ba.isEmpty || bb.isEmpty { return a == b ? 1 : 0 }
        let inter = ba.intersection(bb).count
        let union = ba.union(bb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [String(chars)] }
        var set = Set<String>()
        for i in 0..<(chars.count - 1) { set.insert(String(chars[i...i+1])) }
        return set
    }
}
