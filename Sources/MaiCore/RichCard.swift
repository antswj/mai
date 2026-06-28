import Foundation

// The Step-3 card. Richer than the step-1 Card (which stays the memory-store and
// Face contract, unchanged): a RichCard carries an answer, an optional image, a
// real tappable source, and an optional suggested response, and it is filled in
// ASYNCHRONOUSLY. The card appears instantly as a skeleton and each part lands on
// its own task, so the transcript never stalls waiting on a network lookup.
//
// A RichCard is a value type emitted repeatedly to a RichCardSink: first as a
// skeleton, then re-emitted (upserted by id) as each enrichment part resolves.
// Every part resolves to a TERMINAL state: a value, or "no result" (removed from
// `pending`). A part still in `pending` is loading; a part absent from `pending`
// with a nil value genuinely has nothing, and the UI shows nothing rather than
// shimmering forever.

// The lookup route the card brain chose. The first four are the Step-3 knowledge
// routes; the last three mirror the deterministic structural routes (place,
// prepared reply, screen) so a RichCard can represent any surfaced card.
public enum LookupRoute: String, Codable, Sendable {
    case trivial        // instant local numeric/units/date answer; no web, no image, no source
    case entity         // known entity: Wikipedia summary + image + source
    case fresh          // current/time-sensitive: grounded web search, synthesized + sourced
    case technical      // technical: model analysis, plainly; grounded search when it needs freshness
    case place          // nearby places (deterministic lookup)
    case preparedReply  // meeting-mode prepared line / suggested response
    case screen         // surface the current screen read
    case pending        // not yet routed (skeleton state, before the router call returns)
}

// A real, tappable source. Never fabricated: only set from a lookup that returned
// a genuine URL (Wikipedia article, a grounded-search web result, a maps link).
public struct RichSource: Codable, Sendable, Equatable {
    public let title: String
    public let url: String
    public init(title: String, url: String) { self.title = title; self.url = url }
}

// A suggested response (Part B). Spoken in the conversation's language with reading
// aids rendered in the UI (furigana over kanji, pinyin over hanzi), with an
// interface-language translation underneath. Framed as a suggestion, never forced.
public struct RichResponse: Codable, Sendable, Equatable {
    public let spoken: String        // the reply, in the spoken language
    public let translation: String   // the same reply in the interface language
    public let language: Language    // the spoken language (drives the ruby aid)
    public let rationale: String?    // a short why, in the interface language
    public init(spoken: String, translation: String, language: Language, rationale: String?) {
        self.spoken = spoken; self.translation = translation; self.language = language; self.rationale = rationale
    }
}

public struct RichCard: Sendable, Identifiable, Equatable {
    // The enrichment part keys tracked in `pending`.
    public enum Part: String, Sendable, CaseIterable {
        case route, info, image, source, response
    }

    public let id: String
    public let trigger: TriggerType
    public let timestamp: Date

    public var route: LookupRoute
    public var tier: Tier
    public var score: Double

    public var headline: String              // always present so the skeleton is meaningful
    public var info: String?                 // the answer, ALWAYS in the interface language
    public var imageURL: String?             // real image URL (Wikipedia/Places only); nil when none
    public var source: RichSource?           // real, tappable
    public var response: RichResponse?       // Part B; nil unless warranted
    public var action: Action?               // e.g. open_in_maps for a place
    public var searchSuggestionHTML: String? // Gemini grounded-search Search Suggestions (attribution)

    public var pending: Set<String>          // Part.rawValue still enriching; empty == fully resolved
    public var timings: [String: Int]        // per-part elapsed ms, for tuning
    public var latencyMs: Int?               // time-to-skeleton (first paint)
    public var suppressed: Bool              // surfaced vs shown only in the quiet log
    public var note: String?                 // small caption (e.g. "Suggested reply for Sato")

    public init(
        id: String = UUID().uuidString,
        trigger: TriggerType,
        timestamp: Date,
        route: LookupRoute = .pending,
        tier: Tier = .medium,
        score: Double = 0.5,
        headline: String,
        info: String? = nil,
        imageURL: String? = nil,
        source: RichSource? = nil,
        response: RichResponse? = nil,
        action: Action? = nil,
        searchSuggestionHTML: String? = nil,
        pending: Set<String> = [],
        timings: [String: Int] = [:],
        latencyMs: Int? = nil,
        suppressed: Bool = false,
        note: String? = nil
    ) {
        self.id = id; self.trigger = trigger; self.timestamp = timestamp
        self.route = route; self.tier = tier; self.score = score
        self.headline = headline; self.info = info; self.imageURL = imageURL
        self.source = source; self.response = response; self.action = action
        self.searchSuggestionHTML = searchSuggestionHTML
        self.pending = pending; self.timings = timings; self.latencyMs = latencyMs
        self.suppressed = suppressed; self.note = note
    }

    public var isLoading: Bool { !pending.isEmpty }
    public func isPending(_ part: Part) -> Bool { pending.contains(part.rawValue) }

    // Map the resolved RichCard down to the step-1 Card for the memory store and the
    // Face contract. Keeps a single source of truth (the RichCard stream) while the
    // store and any Card-based consumer still get populated on completion.
    public func toCard() -> Card {
        var lines: [String] = []
        if let info, !info.isEmpty { lines.append(info) }
        if let response { lines.append(response.spoken); lines.append(response.translation) }
        if let note, !note.isEmpty { lines.append(note) }
        if let source { lines.append("Source: \(source.title)") }
        return Card(title: headline, body: lines.joined(separator: "\n"),
                    trigger: trigger, tier: tier, score: score,
                    timestamp: timestamp, action: action, latencyMs: latencyMs)
    }
}

// The new UI emission channel. The engine emits RichCards here (the app), separate
// from the step-1 Face/Card path (the console and tests). Upsert by id: the first
// emit inserts the skeleton, later emits update it in place as parts resolve.
public protocol RichCardSink: Sendable {
    func upsert(_ card: RichCard)
    func suppressed(headline: String, trigger: TriggerType, reason: String)
}
