import Foundation
import NaturalLanguage

// Local redaction of personal information before any text leaves the machine.
//
// Mai transcribes real conversations, and every prompt it builds (classifier windows,
// coaching, replies, lookups, notes) is sent to a hosted provider. This layer removes
// the parts of that text that identify people, and puts them back before anything is
// shown to the user, so the provider sees "Person A" where the user sees "Tanaka".
//
// Two design decisions carry the feature:
//
// 1. Redaction happens ONCE per finalized line, at ingest, not per outbound call. Every
//    prompt is assembled from already-redacted text, so the cost is paid once on a
//    background path and adds nothing to request latency.
// 2. Placeholders are STABLE for the whole session ("Tanaka" is always "Person A"), so
//    the model can still follow who said what across turns. A per-occurrence random
//    token would destroy the conversation's coreference and make replies worse.
//
// Scope, stated honestly: this covers TEXT Mai sends. It does not and cannot cover the
// audio sent for transcription or the screen frames sent for reading, which are the raw
// inputs themselves. Detection is never perfect; this reduces exposure, it does not
// guarantee it.

public enum PIIKind: String, Sendable, CaseIterable {
    case person, email, phone, address, url, creditCard, governmentID
}

public struct PIIPolicy: Sendable, Equatable {
    public var redactPeople: Bool
    public var redactContacts: Bool      // email, phone, address
    public var redactIdentifiers: Bool   // payment and government numbers
    public var redactURLs: Bool

    public init(redactPeople: Bool = true, redactContacts: Bool = true,
                redactIdentifiers: Bool = true, redactURLs: Bool = false) {
        self.redactPeople = redactPeople
        self.redactContacts = redactContacts
        self.redactIdentifiers = redactIdentifiers
        self.redactURLs = redactURLs
    }

    /// Nothing is redacted. Used when the feature is switched off, so the call sites stay
    /// identical either way and there is no second code path to keep correct.
    public static let off = PIIPolicy(redactPeople: false, redactContacts: false,
                                      redactIdentifiers: false, redactURLs: false)

    public var isActive: Bool { redactPeople || redactContacts || redactIdentifiers || redactURLs }

    public func allows(_ kind: PIIKind) -> Bool {
        switch kind {
        case .person: return redactPeople
        case .email, .phone, .address: return redactContacts
        case .creditCard, .governmentID: return redactIdentifiers
        case .url: return redactURLs
        }
    }
}

/// Pure detection: finds spans worth redacting in one line of text. Separated from the
/// mapping so the detectors can be tested on their own.
public enum PIIDetector {
    public struct Span: Sendable, Equatable {
        public let range: Range<String.Index>
        public let kind: PIIKind
        public let text: String
    }

    // Luhn check, so an arbitrary 16-digit number (an order id, a meeting code) is not
    // mistaken for a card.
    public static func passesLuhn(_ digits: String) -> Bool {
        let nums = digits.compactMap { $0.wholeNumberValue }
        guard nums.count >= 13, nums.count <= 19 else { return false }
        var sum = 0
        for (i, d) in nums.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    /// Minimum confidence for a person-name tag. Measured against the system tagger:
    /// real names score high (Sato 0.99, Tanaka 0.94) while place and thing nouns it
    /// mislabels score low (Shinkansen 0.71, Osaka 0.50). Redacting those would gut the
    /// place and entity cards, which are the whole point of the app, so precision matters
    /// more here than squeezing out the last name.
    public static let personConfidenceFloor: Double = 0.85

    private static let cardPattern = try? NSRegularExpression(
        pattern: #"\b(?:\d[ -]?){13,19}\b"#)
    // Japanese My Number: exactly 12 digits, optionally grouped in fours.
    private static let myNumberPattern = try? NSRegularExpression(
        pattern: #"\b\d{4}[ -]?\d{4}[ -]?\d{4}\b"#)

    /// `knownNames` are people Mai already knows are in the conversation (the speaker
    /// roster). They are matched exactly, which is both higher precision and higher recall
    /// than any model: these are the people whose privacy is actually at stake, and the
    /// system tagger misses plenty of them ("Tanaka met Suzuki" tags neither).
    public static func spans(in text: String, policy: PIIPolicy,
                             knownNames: Set<String> = []) -> [Span] {
        guard policy.isActive, !text.isEmpty else { return [] }
        var found: [Span] = []
        let whole = NSRange(location: 0, length: (text as NSString).length)

        // Identifiers FIRST. A 12-digit government id also looks like a phone number to
        // the system detector, and the more specific reading should win.
        if policy.redactIdentifiers {
            if let re = cardPattern {
                for m in re.matches(in: text, range: whole) {
                    guard let r = Range(m.range, in: text) else { continue }
                    let raw = String(text[r])
                    if passesLuhn(raw) { found.append(Span(range: r, kind: .creditCard, text: raw)) }
                }
            }
            if let re = myNumberPattern {
                for m in re.matches(in: text, range: whole) {
                    guard let r = Range(m.range, in: text) else { continue }
                    let raw = String(text[r])
                    if raw.filter(\.isNumber).count == 12, !found.contains(where: { $0.range.overlaps(r) }) {
                        found.append(Span(range: r, kind: .governmentID, text: raw))
                    }
                }
            }
        }

        // Structured contact data: emails, phone numbers, street addresses, links.
        // High precision and multilingual, so it runs whatever the language.
        var types: NSTextCheckingResult.CheckingType = []
        if policy.redactContacts { types.insert(.phoneNumber); types.insert(.address) }
        if policy.redactContacts || policy.redactURLs { types.insert(.link) }
        if !types.isEmpty, let detector = try? NSDataDetector(types: types.rawValue) {
            detector.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match, let r = Range(match.range, in: text) else { return }
                if found.contains(where: { $0.range.overlaps(r) }) { return }
                let raw = String(text[r])
                let kind: PIIKind
                switch match.resultType {
                case .phoneNumber:
                    kind = .phone
                case .address:
                    // Only a REAL address, not a bare place name. The system detector
                    // reports "Osaka" as an address, and redacting place names would
                    // gut the place and entity cards, which are the point of the app.
                    let parts = match.addressComponents ?? [:]
                    let hasStreet = parts[.street] != nil || parts[.zip] != nil
                    guard hasStreet else { return }
                    kind = .address
                case .link:
                    // A bare email is reported as a link with a mailto URL; the matched
                    // TEXT has no scheme, so the URL is what distinguishes the two.
                    kind = (match.url?.scheme?.lowercased() == "mailto") ? .email : .url
                default:
                    return
                }
                guard policy.allows(kind) else { return }
                found.append(Span(range: r, kind: kind, text: raw))
            }
        }

        // Known participants next: exact, case-insensitive, and not dependent on a model
        // guessing right.
        if policy.redactPeople {
            for name in knownNames where name.count >= 2 {
                var searchFrom = text.startIndex
                while let r = text.range(of: name, options: [.caseInsensitive], range: searchFrom..<text.endIndex) {
                    searchFrom = r.upperBound
                    if found.contains(where: { $0.range.overlaps(r) }) { continue }
                    if isWholeWord(r, in: text) {
                        found.append(Span(range: r, kind: .person, text: String(text[r])))
                    }
                }
            }
        }

        // Model-tagged names last: the lowest-precision layer, gated on confidence, and
        // anything already claimed above wins over it.
        if policy.redactPeople {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                                 scheme: .nameType,
                                 options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
                guard tag == .personalName else { return true }
                if found.contains(where: { $0.range.overlaps(range) }) { return true }
                let hypotheses = tagger.tagHypotheses(at: range.lowerBound, unit: .word,
                                                      scheme: .nameType, maximumCount: 4).0
                let confidence = hypotheses[NLTag.personalName.rawValue] ?? 0
                guard confidence >= personConfidenceFloor else { return true }
                found.append(Span(range: range, kind: .person, text: String(text[range])))
                return true
            }
        }

        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Latin scripts need word boundaries so "Ann" does not match inside "announcement".
    /// CJK has no such boundaries, so a substring match is the correct behavior there.
    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        let isLatin = text[range].unicodeScalars.allSatisfy { $0.isASCII }
        guard isLatin else { return true }
        let boundary: (Character?) -> Bool = { c in
            guard let c else { return true }
            return !c.isLetter && !c.isNumber
        }
        let before = range.lowerBound > text.startIndex
            ? text[text.index(before: range.lowerBound)] : nil
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        return boundary(before) && boundary(after)
    }
}

/// Assigns stable placeholders and can put the originals back. Reference type because the
/// mapping must persist for the whole session across many lines; guarded by a lock so
/// the engine and the notes pipeline can share one.
public final class PIIRedactor: @unchecked Sendable {
    private let lock = NSLock()
    private var placeholderFor: [String: String] = [:]   // original (lowercased) -> placeholder
    private var originalFor: [String: String] = [:]      // placeholder -> original
    private var counts: [PIIKind: Int] = [:]
    private var knownNames: Set<String> = []
    public private(set) var policy: PIIPolicy

    public init(policy: PIIPolicy = PIIPolicy()) {
        self.policy = policy
    }

    public func setPolicy(_ p: PIIPolicy) { lock.withLock { policy = p } }

    /// Tell the redactor about someone known to be in the conversation, so their name is
    /// matched exactly rather than left to a model. Speaker labels are the obvious source.
    public func registerKnownName(_ name: String?) {
        guard let name else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // "You", "Speaker 2" and similar are roles, not identities.
        guard trimmed.count >= 2, !Self.roleLabels.contains(trimmed.lowercased()),
              !trimmed.lowercased().hasPrefix("speaker ") else { return }
        lock.withLock { _ = knownNames.insert(trimmed) }
    }

    private static let roleLabels: Set<String> = ["you", "me", "self", "user", "unknown", "guest", "host"]

    /// Everything replaced so far, for the Privacy view. The mapping itself never leaves
    /// the machine and is never written to disk.
    public func mappingCount() -> Int { lock.withLock { originalFor.count } }

    public func redact(_ text: String) -> String {
        let policy = lock.withLock { self.policy }
        guard policy.isActive else { return text }
        let known = lock.withLock { knownNames }
        let spans = PIIDetector.spans(in: text, policy: policy, knownNames: known)
        guard !spans.isEmpty else { return text }

        var out = text
        // Replace from the end so earlier ranges stay valid.
        for span in spans.reversed() {
            let token = placeholder(for: span)
            out.replaceSubrange(span.range, with: token)
        }
        return out
    }

    /// Put the originals back, for anything shown to the user (a card, a reply, notes).
    public func rehydrate(_ text: String) -> String {
        let map = lock.withLock { originalFor }
        guard !map.isEmpty, !text.isEmpty else { return text }
        var out = text
        // Longest placeholders first so "Person A" cannot partially match "Person AB".
        for key in map.keys.sorted(by: { $0.count > $1.count }) {
            guard let original = map[key], out.contains(key) else { continue }
            out = out.replacingOccurrences(of: key, with: original)
        }
        return out
    }

    private func placeholder(for span: PIIDetector.Span) -> String {
        lock.withLock {
            let key = span.kind.rawValue + "|" + span.text.lowercased()
            if let existing = placeholderFor[key] { return existing }
            let n = (counts[span.kind] ?? 0) + 1
            counts[span.kind] = n
            let token = Self.token(kind: span.kind, index: n)
            placeholderFor[key] = token
            originalFor[token] = span.text
            return token
        }
    }

    /// Placeholders read as natural noun phrases so the model still writes fluent replies
    /// around them, and they are short enough not to change the token budget materially.
    public static func token(kind: PIIKind, index: Int) -> String {
        switch kind {
        case .person: return "Person \(letter(index))"
        case .email: return "[email \(index)]"
        case .phone: return "[phone \(index)]"
        case .address: return "[address \(index)]"
        case .url: return "[link \(index)]"
        case .creditCard: return "[card \(index)]"
        case .governmentID: return "[id \(index)]"
        }
    }

    // 1 -> A, 26 -> Z, 27 -> AA.
    public static func letter(_ index: Int) -> String {
        var n = max(1, index)
        var out = ""
        while n > 0 {
            let rem = (n - 1) % 26
            out = String(UnicodeScalar(UInt8(65 + rem))) + out
            n = (n - 1) / 26
        }
        return out
    }
}

/// Wraps a card sink and puts real names back before anything reaches the UI. Placing it
/// at the sink covers BOTH the engine's own emissions and the enricher's incremental
/// re-emissions, so there is exactly one place where rehydration can be forgotten.
public final class RehydratingCardSink: RichCardSink, @unchecked Sendable {
    private let wrapped: RichCardSink
    private let redactor: PIIRedactor

    public init(wrapping wrapped: RichCardSink, redactor: PIIRedactor) {
        self.wrapped = wrapped
        self.redactor = redactor
    }

    public func upsert(_ card: RichCard) {
        wrapped.upsert(rehydrated(card))
    }

    public func suppressed(headline: String, trigger: TriggerType, reason: String) {
        // The suppressed log is shown in the app, so it gets real names back too.
        wrapped.suppressed(headline: redactor.rehydrate(headline), trigger: trigger, reason: reason)
    }

    private func rehydrated(_ card: RichCard) -> RichCard {
        var c = card
        c.headline = redactor.rehydrate(c.headline)
        c.info = c.info.map { redactor.rehydrate($0) }
        if let r = c.response {
            c.response = RichResponse(spoken: redactor.rehydrate(r.spoken),
                                      translation: redactor.rehydrate(r.translation),
                                      language: r.language,
                                      rationale: r.rationale.map { redactor.rehydrate($0) })
        }
        c.trust = c.trust.map {
            TrustSignal(label: $0.label, detail: redactor.rehydrate($0.detail), confidence: $0.confidence)
        }
        return c
    }
}

/// Wraps the step-1 card face so the console and the acceptance harness see real names
/// too. Same rule as the rich sink: the provider saw placeholders, the user never does.
public final class RehydratingFace: Face, @unchecked Sendable {
    private let wrapped: Face
    private let redactor: PIIRedactor

    public init(wrapping wrapped: Face, redactor: PIIRedactor) {
        self.wrapped = wrapped
        self.redactor = redactor
    }

    public func render(_ card: Card) { wrapped.render(rehydrated(card)) }
    public func renderSuppressed(_ card: Card, why: String) {
        wrapped.renderSuppressed(rehydrated(card), why: why)
    }

    private func rehydrated(_ card: Card) -> Card {
        Card(title: redactor.rehydrate(card.title), body: redactor.rehydrate(card.body),
             trigger: card.trigger, tier: card.tier, score: card.score,
             timestamp: card.timestamp, action: card.action, latencyMs: card.latencyMs)
    }
}
