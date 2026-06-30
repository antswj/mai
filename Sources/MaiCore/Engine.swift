import Foundation

// Session metadata, persisted alongside the records.
public struct SessionInfo: Sendable {
    public let id: String
    public let startedAt: Date
    public var endedAt: Date?
    public let interfaceLanguage: String
    public let floorLanguage: String
    public let meetingMode: Bool
    public init(id: String, startedAt: Date, endedAt: Date?, interfaceLanguage: String, floorLanguage: String, meetingMode: Bool) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt
        self.interfaceLanguage = interfaceLanguage; self.floorLanguage = floorLanguage; self.meetingMode = meetingMode
    }
}

// Optional capability for stores that keep a sessions table (SQLiteStore does).
public protocol SessionStore: Sendable {
    func startSession(_ info: SessionInfo) throws
    func endSession(id: String, endedAt: Date) throws
}

// A single merged input: the engine consumes one stream of transcript and screen
// events, exactly as it will when real ears and eyes drop in behind the contracts.
public enum EngineInput: Sendable {
    case transcript(TranscriptEvent)
    case screen(ScreenContentEvent)
}

// The loop. Always-on by construction: it consumes a continuous merged stream and
// never assumes request/response. Everything it depends on is injected, so tests
// pass stubs. Latency is measured from the moment a transcript event arrives to the
// moment its card is emitted (the user-perceived latency, which includes
// classification), set on Card.latencyMs, and warned about past the hard cap.
public actor Engine {
    private let config: Config
    private let store: MemoryStore
    private let verbatim: VerbatimLog
    private let face: Face

    private let classifier: Classifier
    private let dispatcher: Dispatcher
    private let cardize: Cardize
    private let surfacing: Surfacing

    // Step-3 rich path. Present only when a RichCardSink is supplied (the app); when
    // nil the engine keeps the step-1 Card/Face path unchanged (console + tests).
    private let richSink: RichCardSink?
    private let richEnricher: RichCardEnricher?
    // While the assistant chat is open, info/fact cards pause but reply cards keep
    // running in the background, so a suggested reply is never missed.
    private var chatOpen = false

    private var context: RollingContext
    private let session: SessionInfo

    // Always-seeing: the latest stored screen read. Updated only on a change event;
    // a static screen is never re-read, the stored value is reused.
    private var currentScreenText: String = ""

    public var sessionId: String { session.id }

    public init(
        config: Config,
        llm: LLMProvider,
        places: PlacesProvider,
        location: LocationProvider,
        store: MemoryStore,
        verbatim: VerbatimLog,
        face: Face,
        richSink: RichCardSink? = nil,
        entity: EntityLookup? = nil,
        grounded: GroundedSearch? = nil,
        sessionId: String = UUID().uuidString,
        startedAt: Date = Date()
    ) {
        self.config = config
        self.store = store
        self.verbatim = verbatim
        self.face = face
        self.richSink = richSink
        self.context = RollingContext(maxTurns: config.maxTurns, maxSeconds: config.maxSeconds)
        self.classifier = Classifier(llm: llm, model: config.classifierModel,
                                     enabled: config.enabledTriggers,
                                     cooldownSeconds: config.refireCooldownSeconds)
        self.dispatcher = Dispatcher(places: places, location: location,
                                     interfaceLanguage: config.interfaceLanguage,
                                     floorLanguage: config.floorLanguage)
        self.cardize = Cardize(llm: llm, model: config.drafterModel,
                               interfaceLanguage: config.interfaceLanguage,
                               floorLanguage: config.floorLanguage,
                               meetingMode: config.meetingMode,
                               furigana: config.furigana, pinyin: config.pinyin)
        self.surfacing = Surfacing(threshold: config.threshold)
        if let richSink, config.lookupEnabled {
            self.richEnricher = RichCardEnricher(
                config: config, llm: llm,
                entity: entity ?? StubEntityLookup(),
                grounded: grounded ?? StubGroundedSearch(),
                places: places, location: location, sink: richSink)
        } else {
            self.richEnricher = nil
        }
        self.session = SessionInfo(id: sessionId, startedAt: startedAt, endedAt: nil,
                                   interfaceLanguage: config.interfaceLanguage.rawValue,
                                   floorLanguage: config.floorLanguage.rawValue,
                                   meetingMode: config.meetingMode)
        if let s = store as? SessionStore { try? s.startSession(session) }
    }

    // MARK: - Stream consumption

    /// Consume the merged stream until it ends. Real ears/eyes drop in here later.
    public func run(_ stream: AsyncStream<EngineInput>) async {
        for await input in stream {
            await process(input)
        }
    }

    public func process(_ input: EngineInput) async {
        switch input {
        case .transcript(let e): await ingestTranscript(e)
        case .screen(let e): ingestScreen(e)
        }
    }

    // MARK: - Transcript path

    private func ingestTranscript(_ event: TranscriptEvent) async {
        let t0 = Date() // start of the user-perceived latency budget
        context.append(event)
        save(record(kind: "transcript", content: event.text, language: nil, speaker: event.speaker, at: event.timestamp))
        verbatim.appendTranscript(event, sessionId: session.id)

        // Bound the classifier call so a hung LLM request can never freeze the
        // always-on loop (a freeze here would stop every card until it unblocked).
        let window = context.window()
        let ts = event.timestamp
        let triggers = (await withTimeoutOrNil(seconds: max(8, config.onlineCapSeconds * 2)) { [classifier] in
            await classifier.classify(window: window, now: ts)
        }) ?? []
        for trigger in triggers {
            await handle(trigger, event: event, t0: t0)
        }
    }

    private func handle(_ trigger: Trigger, event: TranscriptEvent, t0: Date) async {
        if let enricher = richEnricher {
            handleRich(trigger, event: event, t0: t0, enricher: enricher)
        } else {
            await handleCard(trigger, event: event, t0: t0)
        }
    }

    // MARK: - Rich path (Step 3): instant skeleton, async enrichment, no lag

    public func setChatOpen(_ open: Bool) { chatOpen = open }

    private func handleRich(_ trigger: Trigger, event: TranscriptEvent, t0: Date, enricher: RichCardEnricher) {
        // Reply lock: a reference cue ("your turn", "ご意見を…") yields only a suggested
        // reply, so with the reply toggle off there is nothing to surface for it.
        // Info/fact cards (place, knowledge, screen) always surface regardless.
        if trigger.type == .reference && !config.responseEnabled { return }
        // While the assistant chat is open, pause info and fact cards but keep reply
        // (what-to-say-back) cards running in the background.
        if chatOpen && trigger.type != .reference { return }
        let topic = (trigger.payload["query"] ?? trigger.span).trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = headline(for: trigger, topic: topic)
        let pre = surfacing.preEvaluate(trigger: trigger, headline: headline, now: event.timestamp)
        guard pre.surface else {
            if config.showSuppressedLog { richSink?.suppressed(headline: headline, trigger: trigger.type, reason: pre.reason) }
            return
        }
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)

        // screenReference is already captured: build and persist the card instantly,
        // no enrichment task needed.
        if trigger.type == .screenReference {
            var card = RichCard(trigger: .screenReference, timestamp: event.timestamp, route: .screen,
                                tier: pre.tier, score: pre.score, headline: headline,
                                info: currentScreenText.trimmingCharacters(in: .whitespacesAndNewlines),
                                latencyMs: latencyMs)
            card.pending = []
            richSink?.upsert(card)
            persistRich(card)
            return
        }

        // The language to reply in follows the language actually spoken for THIS
        // utterance: Soniox's detected tag when present, else detected from the text
        // (covers simulated input). The floor config is NOT used here; it applies only
        // to a prepared line where there is no spoken utterance to follow.
        let spoken = Self.spokenLanguage(of: event)
        let (route, request, pending): (LookupRoute, LookupRequest, Set<String>)
        switch trigger.type {
        case .place:
            route = .place
            request = .place(query: topic.isEmpty ? "restaurant" : topic)
            pending = [RichCard.Part.info.rawValue]
        case .reference:
            route = .preparedReply
            request = .preparedReply(context: context.window(), asker: trigger.payload["speaker"], spoken: spoken)
            pending = [RichCard.Part.response.rawValue]
        case .question, .intent:
            route = .pending
            request = .knowledge(topic: topic.isEmpty ? trigger.span : topic, window: context.window(),
                                 spoken: spoken, respond: config.responseEnabled)
            pending = [RichCard.Part.route.rawValue]
        case .screenReference:
            return // handled above
        }

        let skeleton = RichCard(trigger: trigger.type, timestamp: event.timestamp, route: route,
                                tier: pre.tier, score: pre.score, headline: headline,
                                pending: pending, latencyMs: latencyMs)
        richSink?.upsert(skeleton)   // instant first paint, before any lookup

        // Supersede on the SPECIFIC trigger content (same key as the grouping dedup),
        // not the display headline, so two distinct topics never cancel each other's
        // enrichment (the reference headline, for one, is a constant).
        let key = Surfacing.groupingKey(trigger: trigger, headline: headline)
        Task { [weak self] in
            guard let self else { return }
            await enricher.submit(skeleton, request: request, supersedeKey: key) { final in
                Task { await self.persistRich(final) }
            }
        }
    }

    // Per-utterance spoken language: the detected tag from capture, else detected from
    // the text. Never the floor config (which is for prepared lines only).
    public static func spokenLanguage(of event: TranscriptEvent) -> Language {
        if let tag = event.language, let l = Language(rawValue: tag) { return l }
        return ScriptDetect.language(of: event.text)
    }

    private func headline(for trigger: Trigger, topic: String) -> String {
        switch trigger.type {
        case .place: return "Nearby: \(topic.isEmpty ? "places" : topic)"
        case .reference: return "Suggested reply"
        case .screenReference: return "On screen"
        case .question, .intent: return topic.isEmpty ? trigger.span : topic
        }
    }

    private func persistRich(_ card: RichCard) {
        let c = card.toCard()
        save(record(kind: "card", content: cardSummaryLine(c), language: config.interfaceLanguage.rawValue,
                    speaker: nil, at: c.timestamp, meta: cardMeta(c)))
        save(record(kind: "note", content: "Surfaced \(c.tier.rawValue) \(c.trigger.rawValue) card: \(c.title)",
                    language: config.interfaceLanguage.rawValue, speaker: nil, at: c.timestamp))
    }

    // MARK: - Card path (Step 1/2): unchanged

    private func handleCard(_ trigger: Trigger, event: TranscriptEvent, t0: Date) async {
        // screenReference surfaces the current stored screen read; the screen is
        // already captured continuously, the verbal cue only prioritizes it.
        let (result, _) = await dispatcher.dispatch(
            trigger,
            window: context.window(),
            currentScreen: currentScreenText
        )
        guard var card = await cardize.make(trigger: trigger, result: result, now: event.timestamp) else { return }

        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        card = withLatency(card, ms: latencyMs)
        if Double(latencyMs) / 1000.0 > config.hardCapSeconds {
            face.renderSuppressed(card, why: "latency \(latencyMs) ms exceeded hard cap; still shown")
        }

        switch surfacing.evaluate(card: card, trigger: trigger, now: event.timestamp) {
        case .surface(let final):
            let stamped = withLatency(final, ms: latencyMs)
            face.render(stamped)
            save(record(kind: "card", content: cardSummaryLine(stamped), language: config.interfaceLanguage.rawValue, speaker: nil, at: stamped.timestamp, meta: cardMeta(stamped)))
            // Running note in the interface language, saved as its own record.
            save(record(kind: "note", content: "Surfaced \(stamped.tier.rawValue) \(stamped.trigger.rawValue) card: \(stamped.title)", language: config.interfaceLanguage.rawValue, speaker: nil, at: stamped.timestamp))
        case .suppress(let card, let reason):
            if config.showSuppressedLog { face.renderSuppressed(card, why: reason) }
        }
    }

    // MARK: - Screen path (always-seeing)

    private func ingestScreen(_ event: ScreenContentEvent) {
        // The engine always ingests and stores each screen read on change, with no
        // verbal gate. It never re-reads a static screen.
        guard event.isChange else { return }
        currentScreenText = event.content
        save(record(kind: "screen", content: event.content, language: nil, speaker: nil, at: event.timestamp))
        verbatim.appendScreen(event, sessionId: session.id)
    }

    // MARK: - Notes & summary

    /// Generate and store a short session summary in the interface language.
    @discardableResult
    public func summarize(now: Date = Date()) async -> String? {
        let body = await cardize.summary(window: context.allText())
        guard let body, !body.isEmpty else { return nil }
        save(record(kind: "summary", content: body, language: config.interfaceLanguage.rawValue, speaker: nil, at: now))
        return body
    }

    public func endSession(now: Date = Date()) {
        if let s = store as? SessionStore { try? s.endSession(id: session.id, endedAt: now) }
    }

    public func exportSession() throws -> Data {
        try store.exportSession(session.id)
    }

    // MARK: - Record helpers

    private func record(kind: String, content: String, language: String?, speaker: String?, at: Date, meta: [String: String] = [:]) -> MemoryRecord {
        MemoryRecord(id: UUID().uuidString, sessionId: session.id, kind: kind,
                     language: language, speaker: speaker, content: content, timestamp: at, meta: meta)
    }
    private func save(_ r: MemoryRecord) { try? store.save(r) }

    private func cardSummaryLine(_ c: Card) -> String {
        c.body.isEmpty ? c.title : "\(c.title)\n\(c.body)"
    }
    private func cardMeta(_ c: Card) -> [String: String] {
        var m: [String: String] = ["title": c.title, "trigger": c.trigger.rawValue,
                                    "tier": c.tier.rawValue, "score": String(format: "%.2f", c.score)]
        if let ms = c.latencyMs { m["latencyMs"] = String(ms) }
        if let a = c.action { m["action"] = a.kind; m["actionUrl"] = a.params["url"] ?? "" }
        return m
    }
    private func withLatency(_ c: Card, ms: Int) -> Card {
        Card(title: c.title, body: c.body, trigger: c.trigger, tier: c.tier, score: c.score,
             timestamp: c.timestamp, action: c.action, latencyMs: ms)
    }
}

// Merge two async streams into the single merged stream the engine consumes.
public func mergedStream(ears: Ears, eyes: Eyes) -> AsyncStream<EngineInput> {
    AsyncStream { continuation in
        let t = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await e in ears.stream() { continuation.yield(.transcript(e)) }
                }
                group.addTask {
                    for await s in eyes.stream() { continuation.yield(.screen(s)) }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in t.cancel() }
    }
}
