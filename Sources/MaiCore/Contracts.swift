import Foundation

// The contracts: the clean seams between Mai's four swappable layers.
// ears (audio -> transcript), eyes (screen -> text), brain (this engine),
// face (cards -> user). Everything below is plain Swift with no UI dependency.
// All model types are Sendable so they cross actor boundaries safely under
// Swift 6 strict concurrency.

public enum TriggerType: String, Codable, Sendable { case place, question, intent, reference, screenReference }
public enum Tier: String, Codable, Sendable { case critical, medium, noise }
public enum LookupSource: String, Codable, Sendable { case web, places, screen, none }
public enum Language: String, Codable, Sendable { case en, ja, zh }

public struct TranscriptEvent: Codable, Sendable {
    public let text: String
    public let speaker: String?
    public let timestamp: Date
    public let isFinal: Bool
    public init(text: String, speaker: String?, timestamp: Date, isFinal: Bool) {
        self.text = text; self.speaker = speaker; self.timestamp = timestamp; self.isFinal = isFinal
    }
}

public struct ScreenContentEvent: Codable, Sendable {
    public let content: String
    public let timestamp: Date
    public let isChange: Bool
    public init(content: String, timestamp: Date, isChange: Bool) {
        self.content = content; self.timestamp = timestamp; self.isChange = isChange
    }
}

public struct Trigger: Codable, Sendable {
    public let type: TriggerType
    public let span: String
    public let reason: String
    public let confidence: Double
    public let payload: [String: String]
    public init(type: TriggerType, span: String, reason: String, confidence: Double, payload: [String: String]) {
        self.type = type; self.span = span; self.reason = reason; self.confidence = confidence; self.payload = payload
    }
}

public struct Place: Codable, Sendable {
    public let name: String
    public let source: String
    public let rating: Double?
    public let reviewCount: Int?
    public let address: String?
    public let lat: Double?
    public let lng: Double?
    public let url: String?
    public let distanceMeters: Double?
    public init(name: String, source: String, rating: Double?, reviewCount: Int?, address: String?, lat: Double?, lng: Double?, url: String?, distanceMeters: Double?) {
        self.name = name; self.source = source; self.rating = rating; self.reviewCount = reviewCount
        self.address = address; self.lat = lat; self.lng = lng; self.url = url; self.distanceMeters = distanceMeters
    }
}

public struct Action: Codable, Sendable {
    public let kind: String
    public let label: String
    public let params: [String: String]
    public init(kind: String, label: String, params: [String: String]) {
        self.kind = kind; self.label = label; self.params = params
    }
}

public struct Card: Codable, Sendable {
    public let title: String
    public let body: String
    public let trigger: TriggerType
    public let tier: Tier
    public let score: Double
    public let timestamp: Date
    public let action: Action?
    public let latencyMs: Int?
    public init(title: String, body: String, trigger: TriggerType, tier: Tier, score: Double, timestamp: Date, action: Action?, latencyMs: Int?) {
        self.title = title; self.body = body; self.trigger = trigger; self.tier = tier
        self.score = score; self.timestamp = timestamp; self.action = action; self.latencyMs = latencyMs
    }
}

public struct MemoryRecord: Codable, Sendable {
    public let id: String
    public let sessionId: String
    public let kind: String
    public let language: String?
    public let speaker: String?
    public let content: String
    public let timestamp: Date
    public let meta: [String: String]
    public init(id: String, sessionId: String, kind: String, language: String?, speaker: String?, content: String, timestamp: Date, meta: [String: String]) {
        self.id = id; self.sessionId = sessionId; self.kind = kind; self.language = language
        self.speaker = speaker; self.content = content; self.timestamp = timestamp; self.meta = meta
    }
}

// The four layers, as protocols. Real capture (ears/eyes/location) drops in
// later behind these with no logic change; this step uses simulated streams.
public protocol Ears: Sendable {
    func stream() -> AsyncStream<TranscriptEvent>
}
public protocol Eyes: Sendable {
    func stream() -> AsyncStream<ScreenContentEvent>      // continuous; emits a read on each meaningful change
    func currentScreen() async -> ScreenContentEvent?     // latest read on demand
}
public protocol Face: Sendable {
    func render(_ card: Card)
    func renderSuppressed(_ card: Card, why: String)
}
// Text-only by deliberate design: JSON shaping lives in the prompts and is
// parsed defensively by the callers, so this seam stays provider-agnostic.
public protocol LLMProvider: Sendable {
    func complete(system: String, user: String, model: String) async throws -> String
}
public protocol PlacesProvider: Sendable {
    func nearby(query: String, lat: Double, lng: Double, language: Language) async throws -> [Place]
}
public protocol LocationProvider: Sendable {
    func current() async -> (lat: Double, lng: Double)
}
public protocol MemoryStore: Sendable {
    func save(_ record: MemoryRecord) throws
    func exportSession(_ sessionId: String) throws -> Data
}
