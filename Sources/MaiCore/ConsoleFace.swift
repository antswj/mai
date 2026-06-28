import Foundation

// A headless Face. The spec lists this under MaiApp/, but a Face is pure logic
// with no UI dependency, and `swift test` must drive the engine with no UI. To
// keep it usable from both the test target and the app without importing the
// executable target, it lives in MaiCore. It prints to the console and collects
// what it rendered so tests can assert on it.
public final class ConsoleFace: Face, @unchecked Sendable {
    private let lock = NSLock()
    private var _cards: [Card] = []
    private var _suppressed: [(card: Card, why: String)] = []
    private let echo: Bool

    public init(echo: Bool = false) { self.echo = echo }

    public func render(_ card: Card) {
        lock.lock(); _cards.append(card); lock.unlock()
        if echo {
            let lat = card.latencyMs.map { " [\($0)ms]" } ?? ""
            print("CARD [\(card.tier.rawValue)] \(card.title)\(lat)")
            print(indent(card.body))
            if let a = card.action { print("  action: \(a.label) -> \(a.params["url"] ?? "")") }
        }
    }

    public func renderSuppressed(_ card: Card, why: String) {
        lock.lock(); _suppressed.append((card, why)); lock.unlock()
        if echo { print("suppressed [\(card.trigger.rawValue)] \(card.title): \(why)") }
    }

    public var cards: [Card] { lock.lock(); defer { lock.unlock() }; return _cards }
    public var suppressed: [(card: Card, why: String)] { lock.lock(); defer { lock.unlock() }; return _suppressed }
    public func reset() { lock.lock(); _cards = []; _suppressed = []; lock.unlock() }

    private func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n")
    }
}
