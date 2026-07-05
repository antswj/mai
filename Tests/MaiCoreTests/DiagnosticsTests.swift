import Foundation
import Testing
@testable import MaiCore

@Suite struct DiagnosticsTests {
    @Test func telemetryComputesCardTimingsAndSuppression() {
        let card = RichCard(trigger: .question, timestamp: Date(), route: .fresh,
                            headline: "latest", info: "answer",
                            pending: [], timings: ["route": 120, "content": 900],
                            latencyMs: 42, suppressed: true, note: "low usefulness",
                            rating: CardRating(score: 0.9, grade: "excellent", reasons: ["sourced"], useful: true))

        let telemetry = card.telemetry

        #expect(telemetry.firstPaintMs == 42)
        #expect(telemetry.routeMs == 120)
        #expect(telemetry.sourceLookupMs == 900)
        #expect(telemetry.finalFillMs == 900)
        #expect(telemetry.provider == "Grounded Web")
        #expect(telemetry.qualityScore == 0.9)
        #expect(telemetry.suppressionReason == "low usefulness")
    }

    @Test func telemetryComputesPercentilesByRouteAndProvider() {
        let cards = [
            RichCard(trigger: .question, timestamp: Date(), route: .fresh,
                     headline: "one", info: "answer", source: RichSource(title: "DDG", url: "https://duckduckgo.com/a"),
                     pending: [], timings: ["content": 100], latencyMs: 20),
            RichCard(trigger: .question, timestamp: Date(), route: .fresh,
                     headline: "two", info: "answer", source: RichSource(title: "DDG", url: "https://duckduckgo.com/b"),
                     pending: [], timings: ["content": 250], latencyMs: 20),
            RichCard(trigger: .question, timestamp: Date(), route: .fresh,
                     headline: "three", info: "answer", source: RichSource(title: "DDG", url: "https://duckduckgo.com/c"),
                     pending: [], timings: ["content": 400], latencyMs: 20),
        ]

        let rows = LatencyTelemetryStats.percentileRows(from: cards.map(\.telemetry))
        let fresh = rows.first { $0.route == .fresh && $0.provider == "DuckDuckGo" }

        #expect(fresh?.count == 3)
        #expect(fresh?.p50 == 250)
        #expect(fresh?.p95 == 400)
        #expect(fresh?.p99 == 400)
    }

    @Test func feedbackAdjustsUsefulThreshold() {
        let negative = CardFeedbackSummary(useful: 0, notUseful: 4, tooSlow: 2, wrongContext: 2)
        let positive = CardFeedbackSummary(useful: 8, notUseful: 0, tooSlow: 0, wrongContext: 0)

        #expect(negative.adjustedUsefulThreshold() > CardRating.usefulThreshold)
        #expect(positive.adjustedUsefulThreshold() < CardRating.usefulThreshold)
    }

    @Test func feedbackLearnsThresholdsPerRoute() {
        let place = RichCard(trigger: .place, timestamp: Date(), route: .place,
                             headline: "Nearby sushi", pending: [],
                             rating: CardRating(score: 0.7, grade: "good", reasons: [], useful: true))
        let reply = RichCard(trigger: .reference, timestamp: Date(), route: .preparedReply,
                             headline: "Suggested reply", pending: [],
                             rating: CardRating(score: 0.7, grade: "good", reasons: [], useful: true))
        let summary = CardFeedbackSummary.summarize([
            CardFeedbackEntry(card: place, feedback: .wrongContext),
            CardFeedbackEntry(card: place, feedback: .notUseful),
            CardFeedbackEntry(card: reply, feedback: .useful),
            CardFeedbackEntry(card: reply, feedback: .useful),
        ])

        #expect(summary.adjustedUsefulThreshold(for: .place) > CardRating.usefulThreshold)
        #expect(summary.adjustedUsefulThreshold(for: .preparedReply) < CardRating.usefulThreshold)
        #expect(summary.routeThresholds().count == 2)
    }

    @Test func traceAnonymizerPreservesReplayShapeWithoutPrivateText() {
        let event = TranscriptEvent(text: "Alice said the ACME account wants sushi near 555-1212",
                                    speaker: "Alice", timestamp: Date(), isFinal: true, language: "en")
        let trace = TraceAnonymizer.transcript(event, sessionStartedAt: event.timestamp)

        #expect(trace?.text == "I want sushi nearby")
        #expect(trace?.speaker?.hasPrefix("Speaker ") == true)
        #expect(trace?.text.contains("ACME") == false)
    }

    @Test func syntheticSoakGeneratesThirtyMinuteReplay() {
        let trace = SyntheticSoak.trace(durationMinutes: 30, startedAt: Date(timeIntervalSince1970: 0))

        #expect(trace.events.count > 100)
        #expect(trace.events.contains { $0.kind == .screen && ($0.subject ?? "").contains("Salesforce") })
        #expect(trace.events.contains { $0.language == "ja" })
        #expect(trace.events.last?.offsetMs ?? 0 >= 30 * 60 * 1000)
    }

    @Test func cachedEntityLookupAvoidsRepeatedBaseCalls() async throws {
        actor CountBox {
            var count = 0
            func inc() { count += 1 }
            func value() -> Int { count }
        }
        struct CountingEntity: EntityLookup {
            let box: CountBox
            func lookup(term: String, spoken: Language, interface: Language) async throws -> EntityResult? {
                await box.inc()
                return EntityResult(title: term, summary: "summary", imageURL: nil, sourceURL: "https://example.com")
            }
        }

        let box = CountBox()
        let cached = CachedEntityLookup(base: CountingEntity(box: box), ttlSeconds: 60,
                                        cacheURL: maiTempDir().appendingPathComponent("entity.json"))

        _ = try await cached.lookup(term: "Malaysia", spoken: .en, interface: .en)
        _ = try await cached.lookup(term: " malaysia ", spoken: .en, interface: .en)

        #expect(await box.value() == 1)
    }

    @Test func providerCachePersistsAcrossWrapperRestartsAndEvictsByLimit() async throws {
        actor CountBox {
            var count = 0
            func inc() { count += 1 }
            func value() -> Int { count }
        }
        struct CountingEntity: EntityLookup {
            let box: CountBox
            func lookup(term: String, spoken: Language, interface: Language) async throws -> EntityResult? {
                await box.inc()
                return EntityResult(title: term, summary: "summary \(term)", imageURL: nil, sourceURL: "https://example.com/\(term)")
            }
        }

        let box = CountBox()
        let url = maiTempDir().appendingPathComponent("entity.json")
        let first = CachedEntityLookup(base: CountingEntity(box: box), ttlSeconds: 60, maxEntries: 2, cacheURL: url)
        _ = try await first.lookup(term: "Malaysia", spoken: .en, interface: .en)
        let second = CachedEntityLookup(base: CountingEntity(box: box), ttlSeconds: 60, maxEntries: 2, cacheURL: url)
        _ = try await second.lookup(term: "Malaysia", spoken: .en, interface: .en)
        #expect(await box.value() == 1)

        _ = try await second.lookup(term: "Sushi", spoken: .en, interface: .en)
        _ = try await second.lookup(term: "Pudding", spoken: .en, interface: .en)
        let third = CachedEntityLookup(base: CountingEntity(box: box), ttlSeconds: 60, maxEntries: 2, cacheURL: url)
        _ = try await third.lookup(term: "Malaysia", spoken: .en, interface: .en)
        #expect(await box.value() == 4)
    }

    @Test func groundedSearchFallsBackOnQuotaErrors() async throws {
        struct QuotaGrounded: GroundedSearch {
            func answer(query: String, interface: Language) async throws -> GroundedResult {
                struct QuotaError: Error, CustomStringConvertible { let description = "quota exceeded: free_tier" }
                throw QuotaError()
            }
        }
        struct FallbackGrounded: GroundedSearch {
            func answer(query: String, interface: Language) async throws -> GroundedResult {
                GroundedResult(answer: "fallback answer", sources: [RichSource(title: "Fallback", url: "https://example.com")])
            }
        }

        let result = try await FallbackGroundedSearch(primary: QuotaGrounded(), fallback: FallbackGrounded())
            .answer(query: "latest thing", interface: .en)

        #expect(result.answer == "fallback answer")
    }
}
