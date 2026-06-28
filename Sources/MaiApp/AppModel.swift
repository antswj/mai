import Foundation
import MaiCore

// What the Face emits, carried over an AsyncStream so the actor-isolated engine can
// hand cards to the @MainActor model without unsafe cross-actor capture.
enum FaceEvent: Sendable {
    case surfaced(Card)
    case suppressed(Card, String)
}

// A Face that forwards everything into an AsyncStream. Sendable: it only holds the
// stream continuation, which is itself Sendable.
final class StreamFace: Face, @unchecked Sendable {
    private let cont: AsyncStream<FaceEvent>.Continuation
    init(_ cont: AsyncStream<FaceEvent>.Continuation) { self.cont = cont }
    func render(_ card: Card) { cont.yield(.surfaced(card)) }
    func renderSuppressed(_ card: Card, why: String) { cont.yield(.suppressed(card, why)) }
}

struct DisplayItem: Identifiable {
    let id = UUID()
    let card: Card
    let suppressed: Bool
    let why: String?
}

// Owns the engine, feeds it simulated events, and publishes the card stream to the
// SwiftUI views. The real always-on capture (ears/eyes) drops in behind the same
// engine later; this model stands in for it now.
@MainActor
final class AppModel: ObservableObject {
    @Published var items: [DisplayItem] = []   // newest first
    @Published var showSuppressed: Bool = true
    @Published var floorLanguage: String
    @Published var status: String = ""

    private let engine: Engine
    let config: Config

    // Fixtures live in the test target's resources during development; the app
    // reads them from the source tree when run via `swift run` from the package root.
    let fixtures = ["meeting_ja_en.txt", "meeting_zh.txt", "casual.txt"]

    init() {
        let config = Config.load()
        let secrets = Secrets()
        self.config = config
        self.floorLanguage = config.floorLanguage.rawValue
        self.showSuppressed = config.showSuppressedLog

        let (stream, cont) = AsyncStream<FaceEvent>.makeStream()
        let face = StreamFace(cont)
        let store: MemoryStore = (try? SQLiteStore(path: "data/mai.sqlite")) ?? StubStore()
        let verbatim = VerbatimLog()
        let llm = MaiFactory.makeLLM(config: config, secrets: secrets)
        let places = MaiFactory.makePlaces(config: config, secrets: secrets)
        let location = MaiFactory.makeLocation(config: config)

        self.engine = Engine(config: config, llm: llm, places: places, location: location,
                             store: store, verbatim: verbatim, face: face)

        // Consume the face stream on the main actor and publish.
        Task { [weak self] in
            for await ev in stream {
                guard let self else { continue }
                switch ev {
                case .surfaced(let card): self.items.insert(DisplayItem(card: card, suppressed: false, why: nil), at: 0)
                case .suppressed(let card, let why): self.items.insert(DisplayItem(card: card, suppressed: true, why: why), at: 0)
                }
            }
        }
        let provider = config.llmProvider
        status = "Ready. LLM: \(provider) (\(config.classifierModel) / \(config.drafterModel)). Places: \(config.placesProvider). Floor: \(config.floorLanguage.rawValue)."
    }

    func injectLine(_ raw: String) {
        let (speaker, text) = Self.parseSpeaker(raw)
        guard !text.isEmpty else { return }
        let event = TranscriptEvent(text: text, speaker: speaker, timestamp: Date(), isFinal: true)
        Task { await engine.process(.transcript(event)) }
    }

    func injectScreen(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let event = ScreenContentEvent(content: t, timestamp: Date(), isChange: true)
        Task {
            await engine.process(.screen(event))
            await MainActor.run { self.status = "Screen updated (stored, not surfaced until pointed at)." }
        }
    }

    func summarize() {
        Task {
            if let s = await engine.summarize() {
                await MainActor.run {
                    let card = Card(title: "Session summary", body: s, trigger: .question, tier: .medium,
                                    score: 1, timestamp: Date(), action: nil, latencyMs: nil)
                    self.items.insert(DisplayItem(card: card, suppressed: false, why: nil), at: 0)
                }
            }
        }
    }

    func loadFixture(_ name: String) {
        let paths = ["Tests/MaiCoreTests/Fixtures/\(name)", name]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            status = "Fixture not found: \(name)"
            return
        }
        status = "Replaying \(name)..."
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        Task {
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                if t.hasPrefix("[SCREEN]") {
                    let content = String(t.dropFirst("[SCREEN]".count)).trimmingCharacters(in: .whitespaces)
                    await engine.process(.screen(ScreenContentEvent(content: content, timestamp: Date(), isChange: true)))
                } else {
                    let (speaker, body) = Self.parseSpeaker(t)
                    if body.isEmpty { continue }
                    await engine.process(.transcript(TranscriptEvent(text: body, speaker: speaker, timestamp: Date(), isFinal: true)))
                }
            }
            await MainActor.run { self.status = "Replayed \(name)." }
        }
    }

    static func parseSpeaker(_ raw: String) -> (String?, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.firstIndex(of: ":") {
            let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Treat "Name: text" as a speaker only if the name is short and word-like.
            if !name.isEmpty && name.count <= 24 && !name.contains(" ") && !rest.isEmpty {
                return (name, rest)
            }
        }
        return (nil, trimmed)
    }
}

// Minimal no-op store fallback if the SQLite file cannot be opened (keeps the app
// running). The real store is SQLiteStore.
final class StubStore: MemoryStore, @unchecked Sendable {
    func save(_ record: MemoryRecord) throws {}
    func exportSession(_ sessionId: String) throws -> Data { Data("{}".utf8) }
}
