import Foundation
import Testing
@testable import MaiCore

final class GoldenTraceSink: RichCardSink, @unchecked Sendable {
    private let lock = NSLock()
    private var cards: [String: RichCard] = [:]
    private var order: [String] = []

    func upsert(_ card: RichCard) {
        lock.withLock {
            if cards[card.id] == nil { order.append(card.id) }
            cards[card.id] = card
        }
    }

    func suppressed(headline: String, trigger: TriggerType, reason: String) {
        upsert(RichCard(trigger: trigger, timestamp: Date(), route: .pending,
                        tier: .noise, score: 0, headline: headline,
                        pending: [], suppressed: true, note: reason))
    }

    var all: [RichCard] {
        lock.withLock { order.compactMap { cards[$0] } }
    }
}

@Suite struct GoldenTraceTests {
    @Test func badSessionGoldenTraceReplaysIntoUsefulLowLatencyCards() async throws {
        let trace = try loadGoldenTrace("golden_trace_bad_session_v1")
        let dir = maiTempDir()
        let store = try SQLiteStore(path: dir.appendingPathComponent("mai.sqlite").path)
        let verbatim = VerbatimLog(directory: dir.path, filename: "verbatim.jsonl")
        let sink = GoldenTraceSink()
        let config = Config(hardCapSeconds: 3, responseEnabled: true, onlineCapSeconds: 5)
        let engine = Engine(config: config,
                            llm: StubLLM(),
                            places: CachedPlacesProvider(base: StubPlaces(),
                                                         cacheURL: dir.appendingPathComponent("places.json")),
                            location: FixedLocation(lat: config.testLat, lng: config.testLng),
                            store: store,
                            verbatim: verbatim,
                            face: ConsoleFace(),
                            richSink: sink,
                            entity: CachedEntityLookup(base: StubEntityLookup(),
                                                       cacheURL: dir.appendingPathComponent("entity.json")),
                            grounded: CachedGroundedSearch(base: StubGroundedSearch(),
                                                           cacheURL: dir.appendingPathComponent("grounded.json")))

        for event in trace.events {
            await engine.process(trace.input(for: event))
        }
        for _ in 0..<400 {
            let cards = sink.all
            if cards.count >= 6 && !cards.contains(where: { !$0.suppressed && !$0.pending.isEmpty }) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let cards = sink.all.filter { !$0.suppressed && $0.pending.isEmpty }
        let routes = Set(cards.map(\.route))

        #expect(routes.contains(.technical))
        #expect(routes.contains(.trivial))
        #expect(routes.contains(.place))
        #expect(routes.contains(.fresh))
        #expect(routes.contains(.preparedReply))
        #expect(cards.contains { $0.headline.localizedCaseInsensitiveContains("Salesforce") && $0.source != nil })
        #expect(cards.contains { $0.route == .fresh && !$0.sources.isEmpty })
        #expect(cards.contains { $0.route == .preparedReply && $0.response?.spoken.isEmpty == false })
        #expect(cards.allSatisfy { ($0.latencyMs ?? 0) <= 3000 })
        #expect(cards.allSatisfy { ($0.rating?.score ?? 0) >= CardRating.usefulThreshold })
    }

    private func loadGoldenTrace(_ name: String) throws -> MaiTrace {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw NSError(domain: "GoldenTraceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.mai.decode(MaiTrace.self, from: data)
    }
}
