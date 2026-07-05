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
    private static let promptContextMaxChars = 6_000
    private static let screenContextMaxChars = 4_000

    private let config: Config
    private let store: MemoryStore
    private let verbatim: VerbatimLog
    private let face: Face
    private let llm: LLMProvider

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
    private var currentScreenSubject: String?   // the salient subject to look up
    private var currentScreenAppName: String?
    private var currentScreenBundleIdentifier: String?
    private var currentScreenWindowTitle: String?
    private var recentCoaching: [String: Date] = [:]

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
        self.llm = llm
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
        maybeSurfaceCoaching(event: event, window: context.window(maxChars: 2_000), t0: t0)

        // Bound the classifier call so a hung LLM request can never freeze the
        // always-on loop (a freeze here would stop every card until it unblocked).
        let window = context.window(maxChars: Self.promptContextMaxChars)
        let ts = event.timestamp
        let classifierCap = max(0.25, min(config.hardCapSeconds, config.onlineCapSeconds))
        let triggers = (await withTimeoutOrNil(seconds: classifierCap) { [classifier] in
            await classifier.classify(window: window, now: ts)
        }) ?? []
        for trigger in triggers {
            await handle(trigger, event: event, window: window, t0: t0)
        }
    }

    private func handle(_ trigger: Trigger, event: TranscriptEvent, window: String, t0: Date) async {
        if let enricher = richEnricher {
            handleRich(trigger, event: event, window: window, t0: t0, enricher: enricher)
        } else {
            await handleCard(trigger, event: event, window: window, t0: t0)
        }
    }

    // MARK: - Rich path (Step 3): instant skeleton, async enrichment, no lag

    public func setChatOpen(_ open: Bool) { chatOpen = open }

    private func handleRich(_ trigger: Trigger, event: TranscriptEvent, window: String, t0: Date, enricher: RichCardEnricher) {
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

        // A verbal "look at the screen" cue surfaces a USEFUL, sourced card about the
        // screen's subject (run through the lookup router), not a description. If there
        // is no identifiable subject, fall back to showing the stored read (the user
        // explicitly asked to see the screen).
        if trigger.type == .screenReference {
            if let subject = currentScreenSubject, !subject.isEmpty {
                surfaceScreenCard(subject: subject, content: currentScreenContext(), now: event.timestamp,
                                  tier: pre.tier, score: pre.score, latencyMs: latencyMs, enricher: enricher)
            } else {
                var card = RichCard(trigger: .screenReference, timestamp: event.timestamp, route: .screen,
                                    tier: pre.tier, score: pre.score, headline: headline,
                                    info: currentScreenContext().trimmingCharacters(in: .whitespacesAndNewlines),
                                    latencyMs: latencyMs,
                                    trust: screenTrust(subject: nil, triggerReason: trigger.reason))
                card.pending = []
                card.rating = CardRating.evaluate(card)
                if card.rating?.useful == false {
                    card.suppressed = true
                    card.tier = .noise
                    card.note = "low usefulness: \(card.rating?.grade ?? "weak")"
                }
                richSink?.upsert(card)
                persistRich(card)
            }
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
            request = .preparedReply(context: window, asker: trigger.payload["speaker"], spoken: spoken)
            pending = [RichCard.Part.response.rawValue]
        case .question, .intent:
            route = .pending
            request = .knowledge(topic: topic.isEmpty ? trigger.span : topic, window: window,
                                 spoken: spoken, respond: config.responseEnabled)
            pending = [RichCard.Part.route.rawValue]
        case .screenReference:
            return // handled above
        }

        let skeleton = RichCard(trigger: trigger.type, timestamp: event.timestamp, route: route,
                                tier: pre.tier, score: pre.score, headline: headline,
                                pending: pending, latencyMs: latencyMs,
                                trust: triggerTrust(trigger: trigger, event: event))
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
        guard !card.suppressed else { return }
        let c = card.toCard()
        var meta = cardMeta(c)
        if let rating = card.rating {
            meta["rating"] = String(format: "%.2f", rating.score)
            meta["ratingGrade"] = rating.grade
        }
        if !card.trust.isEmpty {
            meta["trust"] = card.trust.prefix(4).map { "\($0.label): \($0.detail)" }.joined(separator: " | ")
        }
        save(record(kind: "card", content: cardSummaryLine(c), language: config.interfaceLanguage.rawValue,
                    speaker: nil, at: c.timestamp, meta: meta))
        save(record(kind: "note", content: "Surfaced \(c.tier.rawValue) \(c.trigger.rawValue) card: \(c.title)",
                    language: config.interfaceLanguage.rawValue, speaker: nil, at: c.timestamp))
    }

    // MARK: - Card path (Step 1/2): unchanged

    private func handleCard(_ trigger: Trigger, event: TranscriptEvent, window: String, t0: Date) async {
        // screenReference surfaces the current stored screen read; the screen is
        // already captured continuously, the verbal cue only prioritizes it.
        let (result, _) = await dispatcher.dispatch(
            trigger,
            window: window,
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
        currentScreenSubject = event.subject
        currentScreenAppName = event.appName
        currentScreenBundleIdentifier = event.bundleIdentifier
        currentScreenWindowTitle = event.windowTitle
        save(record(kind: "screen", content: event.content, language: nil, speaker: nil, at: event.timestamp,
                    meta: screenMeta(event)))
        verbatim.appendScreen(event, sessionId: session.id)

        // Rich path: a settled screen change proactively surfaces a USEFUL, sourced card
        // about the slide's subject (no verbal cue required), so a presentation produces
        // cards on its own. Only when there is a real subject to look up; deduped per
        // subject so the same slide does not refire and a later verbal cue does not
        // double-fire. Paused while the chat is open (it is an info card).
        guard let enricher = richEnricher, !chatOpen,
              let subject = event.subject, !subject.isEmpty else { return }
        surfaceScreenCard(subject: subject, content: currentScreenContext(), now: event.timestamp,
                          tier: .medium, score: 0.75, latencyMs: 0, enricher: enricher)
    }

    // Surface a useful, sourced card about a screen subject by running it through the
    // lookup router (entity/fresh/technical), in the interface language. Shared by the
    // proactive screen-change path and the verbal "look at the screen" cue, deduped on
    // the subject so they never double-fire for the same content.
    private func surfaceScreenCard(subject: String, content: String, now: Date,
                                   tier: Tier, score: Double, latencyMs: Int, enricher: RichCardEnricher) {
        let trig = Trigger(type: .screenReference, span: subject, reason: "screen subject",
                           confidence: score, payload: ["query": subject])
        let pre = surfacing.preEvaluate(trigger: trig, headline: subject, now: now)
        guard pre.surface else {
            if config.showSuppressedLog { richSink?.suppressed(headline: subject, trigger: .screenReference, reason: pre.reason) }
            return
        }
        let skeleton = RichCard(trigger: .screenReference, timestamp: now, route: .pending,
                                tier: pre.tier, score: pre.score, headline: subject,
                                pending: [RichCard.Part.route.rawValue], latencyMs: latencyMs,
                                trust: screenTrust(subject: subject, triggerReason: trig.reason))
        richSink?.upsert(skeleton)
        // Look the subject up like any knowledge query; the screen text is the context.
        // Interface language drives the answer; native subject names resolve cross-language.
        let request = LookupRequest.knowledge(topic: subject, window: Self.clippedContext(content, maxChars: Self.screenContextMaxChars),
                                              spoken: config.interfaceLanguage, respond: false)
        let key = Surfacing.groupingKey(trigger: trig, headline: subject)
        Task { [weak self] in
            guard let self else { return }
            await enricher.submit(skeleton, request: request, supersedeKey: key) { final in
                Task { await self.persistRich(final) }
            }
        }
    }

    private func maybeSurfaceCoaching(event: TranscriptEvent, window: String, t0: Date) {
        guard richSink != nil, !chatOpen else { return }
        if let insight = ConversationCoach.insight(for: event, window: window) {
            if recentCoaching[insight.key].map({ event.timestamp.timeIntervalSince($0) >= 90 }) ?? true {
                recentCoaching[insight.key] = event.timestamp
                surfaceCoaching(insight, event: event, t0: t0)
            }
        }
        scheduleAICoaching(event: event, window: window, t0: t0)
    }

    private func scheduleAICoaching(event: TranscriptEvent, window: String, t0: Date) {
        guard config.coachingAIEnabled,
              let vocal = event.vocalSignal,
              vocal.capturedSeconds >= 0.4,
              vocal.speechSeconds >= 0.2 else { return }
        let speaker = event.speaker?.isEmpty == false ? event.speaker! : "speaker"
        let key = "ai-vocal|\(speaker)"
        let interval = max(10, config.coachingAIMinIntervalSeconds)
        if let last = recentCoaching[key], event.timestamp.timeIntervalSince(last) < interval { return }
        recentCoaching[key] = event.timestamp
        Task { [event, window, t0] in
            await self.surfaceAICoaching(event: event, window: window, t0: t0)
        }
    }

    private func surfaceAICoaching(event: TranscriptEvent, window: String, t0: Date) async {
        guard richSink != nil, !chatOpen else { return }
        let started = Date()
        let cap = max(2, config.coachingAICapSeconds)
        let model = config.coachingAIModel.isEmpty ? config.lookupRouterModel : config.coachingAIModel
        guard let insight = await withTimeoutOrNil(seconds: cap, { [llm, config] in
            try await ConversationCoach.requireAIInsight(
                for: event, window: window, llm: llm, model: model,
                interfaceLanguage: config.interfaceLanguage)
        }) else { return }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        surfaceCoaching(insight, event: event, t0: t0,
                        note: "AI voice coaching",
                        timings: ["ai_coach": elapsed])
    }

    private func surfaceCoaching(_ insight: CoachingInsight, event: TranscriptEvent, t0: Date,
                                 note: String? = nil, timings: [String: Int] = [:]) {
        var card = RichCard(trigger: .intent, timestamp: event.timestamp, route: .coaching,
                            tier: insight.tier, score: insight.score, headline: insight.headline,
                            info: insight.info, pending: [],
                            timings: timings,
                            latencyMs: Int(Date().timeIntervalSince(t0) * 1000),
                            note: note,
                            trust: insight.trust)
        card.rating = CardRating.evaluate(card)
        richSink?.upsert(card)
        persistRich(card)
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

    private func screenMeta(_ event: ScreenContentEvent) -> [String: String] {
        var meta: [String: String] = [:]
        if let subject = event.subject, !subject.isEmpty { meta["subject"] = subject }
        if let appName = event.appName, !appName.isEmpty { meta["appName"] = appName }
        if let bundle = event.bundleIdentifier, !bundle.isEmpty { meta["bundleIdentifier"] = bundle }
        if let title = event.windowTitle, !title.isEmpty { meta["windowTitle"] = title }
        return meta
    }

    private func currentScreenContext() -> String {
        var parts: [String] = []
        if let app = currentScreenAppName, !app.isEmpty { parts.append("Active app: \(app)") }
        if let title = currentScreenWindowTitle, !title.isEmpty { parts.append("Window: \(title)") }
        if let bundle = currentScreenBundleIdentifier, !bundle.isEmpty { parts.append("Bundle: \(bundle)") }
        let text = currentScreenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append("Screen read: \(text)") }
        return parts.joined(separator: "\n")
    }

    private func triggerTrust(trigger: Trigger, event: TranscriptEvent) -> [TrustSignal] {
        var trust = [
            TrustSignal(label: "Trigger", detail: "\(trigger.type.rawValue): \(trigger.reason)", confidence: trigger.confidence),
            TrustSignal(label: "Evidence", detail: Self.clippedTrustText(event.text), confidence: min(0.95, max(0.45, trigger.confidence)))
        ]
        if let speaker = event.speaker, !speaker.isEmpty {
            trust.append(TrustSignal(label: "Speaker", detail: speaker, confidence: 0.82))
        }
        return trust
    }

    private func screenTrust(subject: String?, triggerReason: String) -> [TrustSignal] {
        var trust = [TrustSignal(label: "Trigger", detail: triggerReason, confidence: 0.78)]
        if let subject, !subject.isEmpty {
            trust.append(TrustSignal(label: "Screen subject", detail: subject, confidence: 0.76))
        }
        if let app = currentScreenAppName, !app.isEmpty {
            trust.append(TrustSignal(label: "Active app", detail: app, confidence: 0.86))
        }
        if let title = currentScreenWindowTitle, !title.isEmpty {
            trust.append(TrustSignal(label: "Window", detail: Self.clippedTrustText(title), confidence: 0.72))
        }
        return trust
    }
    private func withLatency(_ c: Card, ms: Int) -> Card {
        Card(title: c.title, body: c.body, trigger: c.trigger, tier: c.tier, score: c.score,
             timestamp: c.timestamp, action: c.action, latencyMs: ms)
    }

    private static func clippedContext(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        guard text.count > maxChars else { return text }
        let prefix = "[earlier content omitted to fit context]\n"
        let budget = max(0, maxChars - prefix.count)
        guard budget > 0 else { return String(prefix.prefix(maxChars)) }
        return prefix + String(text.suffix(budget))
    }

    private static func clippedTrustText(_ text: String, maxChars: Int = 140) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        return String(trimmed.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
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
