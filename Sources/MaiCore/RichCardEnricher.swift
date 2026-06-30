import Foundation

// What the engine asks the enricher to look up, derived from the trigger. The
// structural routes (place / preparedReply / screen) are known up front; the
// knowledge route is decided by the card brain (LookupRouter) as the first
// enrichment step.
public enum LookupRequest: Sendable {
    case knowledge(topic: String, window: String, spoken: Language, respond: Bool)
    case place(query: String)
    case preparedReply(context: String, asker: String?, spoken: Language)
    case screen(text: String)
}

// Part C: async enrichment with no lag. The card is already on screen (the engine
// emitted the skeleton synchronously) before this runs. Each part lands on its own
// task with a hard timeout; results are applied and re-emitted incrementally so the
// card fills in live. A new card with the same supersede key cancels the previous
// one's in-flight work. Every part resolves to a terminal state (a value, or a
// removal from `pending`); on completion the resolved card is mapped to a step-1
// Card via onComplete so the memory store stays populated.
public actor RichCardEnricher {
    private let config: Config
    private let llm: LLMProvider
    private let router: LookupRouter
    private let entity: EntityLookup
    private let grounded: GroundedSearch
    private let places: PlacesProvider
    private let location: LocationProvider
    private let sink: RichCardSink
    private let interface: Language
    private let floor: Language

    private var tasks: [String: Task<Void, Never>] = [:]

    public init(config: Config, llm: LLMProvider, entity: EntityLookup, grounded: GroundedSearch,
                places: PlacesProvider, location: LocationProvider, sink: RichCardSink) {
        self.config = config
        self.llm = llm
        self.router = LookupRouter(llm: llm, model: config.lookupRouterModel, interface: config.interfaceLanguage)
        self.entity = entity
        self.grounded = grounded
        self.places = places
        self.location = location
        self.sink = sink
        self.interface = config.interfaceLanguage
        self.floor = config.floorLanguage
    }

    // Start enriching an already-emitted skeleton. Cancels any prior in-flight work
    // for the same supersede key first.
    public func submit(_ skeleton: RichCard, request: LookupRequest,
                       supersedeKey: String, onComplete: @escaping @Sendable (RichCard) -> Void) {
        tasks[supersedeKey]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(skeleton, request: request, onComplete: onComplete)
            await self.clear(supersedeKey)
        }
        tasks[supersedeKey] = task
    }

    public func cancelAll() {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
    }

    private func clear(_ key: String) { tasks[key] = nil }
    private func emit(_ card: RichCard) { if !Task.isCancelled { sink.upsert(card) } }

    // MARK: - Run

    private func run(_ skeleton: RichCard, request: LookupRequest, onComplete: @escaping @Sendable (RichCard) -> Void) async {
        var card = skeleton
        let t0 = Date()

        switch request {
        case .screen(let text):
            card.route = .screen
            card.info = text.trimmingCharacters(in: .whitespacesAndNewlines)
            card.pending.removeAll()
            emit(card)

        case .place(let query):
            card.route = .place
            await runContentAndResponse(&card, content: { [self] in await placeContent(query: query) },
                                        respond: false, window: "", screen: "", spoken: interface)

        case .preparedReply(let context, let asker, let spoken):
            card.route = .preparedReply
            let who = (asker?.isEmpty == false) ? asker : nil
            await runContentAndResponse(&card, content: { [self] in await preparedReplyContent(context: context, asker: who, spoken: spoken) },
                                        respond: false, window: context, screen: "", spoken: spoken)

        case .knowledge(let topic, let window, let spoken, let respond):
            // Route first (its own timeout + default-route fallback), then enrich.
            let routerCap = min(config.onlineCapSeconds, 3)
            let plan = (await withTimeoutOrNil(seconds: routerCap) { [router] in await router.plan(topic: topic, window: window, spoken: spoken) })
                ?? LookupRouter.fallback(topic: topic, spoken: spoken)
            card.route = plan.route
            card.timings["route"] = ms(t0)
            card.pending = pendingForKnowledge(plan: plan, respond: respond)
            emit(card)

            if plan.route == .trivial {
                card.info = plan.trivialAnswer
                card.pending.remove(RichCard.Part.info.rawValue)
                card.timings["info"] = ms(t0)
                emit(card)
                if respond { await runResponseOnly(&card, window: window, screen: "", spoken: spoken) }
            } else {
                await runContentAndResponse(&card, content: { [self] in await knowledgeContent(plan: plan, topic: topic, window: window) },
                                            respond: respond, window: window, screen: "", spoken: spoken)
            }
        }

        card.pending.removeAll()
        emit(card)
        if !Task.isCancelled { onComplete(card) }
    }

    // Run the content fetch and (optionally) the response fetch concurrently, each on
    // its own task, applying and re-emitting as each resolves.
    private func runContentAndResponse(_ card: inout RichCard,
                                       content: @escaping @Sendable () async -> ContentOutcome,
                                       respond: Bool, window: String, screen: String, spoken: Language) async {
        await withTaskGroup(of: PartOutcome.self) { group in
            group.addTask { let s = Date(); let o = await content(); return .content(o, ms(s)) }
            if respond {
                group.addTask { [self] in let s = Date(); let r = await fetchResponse(window: window, screen: screen, spoken: spoken); return .response(r, ms(s)) }
            }
            for await outcome in group {
                if Task.isCancelled { break }
                apply(outcome, to: &card)
                emit(card)
            }
        }
    }

    private func runResponseOnly(_ card: inout RichCard, window: String, screen: String, spoken: Language) async {
        let s = Date()
        let r = await fetchResponse(window: window, screen: screen, spoken: spoken)
        if Task.isCancelled { return }
        apply(.response(r, ms(s)), to: &card)
        emit(card)
    }

    // MARK: - Content fetchers (nonisolated: run off-actor, concurrently)

    private nonisolated func knowledgeContent(plan: LookupPlan, topic: String, window: String) async -> ContentOutcome {
        // A card should ALWAYS end up with some info. Try the best-sourced lookup
        // first, but if it comes up empty, fall through to a grounded answer and then
        // to the model's own general knowledge, rather than showing "nothing found".
        // Sourced is preferred, not required; one source (or none, for a plain
        // knowledge answer) is fine. Nothing is invented: a plain answer simply
        // carries no source line.
        // The model answer is a TRUE last resort everywhere: every non-trivial route
        // tries a real, sourced lookup first (Wikipedia for an entity, grounded web
        // search otherwise) and only falls to the model when both find nothing, marked
        // unverified with no source line.
        switch plan.route {
        case .entity:
            let term = plan.entity ?? topic
            let found: EntityResult? = (await withTimeoutOrNil(seconds: config.onlineCapSeconds) { [entity, interface] in
                try await entity.lookup(term: term, spoken: plan.spoken, interface: interface)
            }) ?? nil
            if let r = found {
                let src = RichSource(title: r.sourceTitle, url: r.sourceURL)
                return ContentOutcome(info: r.summary, image: r.imageURL, source: src,
                                      html: nil, action: nil, sources: [src])
            }
            let grounded = await groundedContent(query: plan.query)
            if grounded.info != nil { return grounded }
            return await explainContent(topic: topic, window: window)
        case .fresh, .technical:
            // Both go to grounded web search first; the model is the fallback only when
            // search returns nothing. (Technical no longer short-circuits to the model.)
            let grounded = await groundedContent(query: plan.query)
            if grounded.info != nil { return grounded }
            return await explainContent(topic: topic, window: window)
        default:
            let grounded = await groundedContent(query: plan.query)
            if grounded.info != nil { return grounded }
            return await explainContent(topic: topic, window: window)
        }
    }

    // Last-resort content: the model's own general knowledge, no web, no source. Marked
    // unverified so the card is labeled and shows no source line.
    private nonisolated func explainContent(topic: String, window: String) async -> ContentOutcome {
        let answer: String? = (await withTimeoutOrNil(seconds: config.onlineCapSeconds) { [self] in
            try await explain(topic: topic, window: window)
        }) ?? nil
        return ContentOutcome(info: answer, image: nil, source: nil, html: nil, action: nil, unverified: answer != nil)
    }

    private nonisolated func groundedContent(query: String) async -> ContentOutcome {
        let g: GroundedResult? = (await withTimeoutOrNil(seconds: config.onlineCapSeconds) { [grounded, interface] in
            try await grounded.answer(query: query, interface: interface)
        }) ?? nil
        guard let g, !g.answer.isEmpty else {
            return ContentOutcome(info: nil, image: nil, source: nil, html: nil, action: nil)
        }
        return ContentOutcome(info: g.answer, image: nil, source: g.sources.first,
                              html: g.searchSuggestionHTML, action: nil, sources: g.sources)
    }

    private nonisolated func explain(topic: String, window: String) async throws -> String? {
        let user = """
        Interface language: \(LookupRouter.name(interface))
        Question: \(topic)
        Recent conversation (for context, newest last):
        \(window)
        Produce the JSON now.
        """
        let raw = try await llm.complete(system: Prompts.explainer, user: user, model: config.drafterModel)
        let answer = (JSONExtract.decodeObject(raw)?["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (answer?.isEmpty == false) ? answer : nil
    }

    private nonisolated func placeContent(query: String) async -> ContentOutcome {
        let loc = await location.current()
        let results: [Place] = (await withTimeoutOrNil(seconds: config.onlineCapSeconds) { [places, floor] in
            try await places.nearby(query: query, lat: loc.lat, lng: loc.lng, language: floor)
        }) ?? nil ?? []
        guard let best = results.first else {
            return ContentOutcome(info: "No nearby matches found right now.", image: nil, source: nil, html: nil, action: nil)
        }
        var lines: [String] = []
        var head = best.name
        if let r = best.rating { head += "  ★\(trimNum(r))" + (best.reviewCount.map { " (\($0))" } ?? "") }
        lines.append(head)
        if let d = best.distanceMeters { lines.append("~\(Int(d.rounded())) m away") }
        if let addr = best.address, !addr.isEmpty { lines.append(addr) }
        if best.source == "hotpepper" { lines.append("Powered by ホットペッパーグルメ Webサービス") }
        let action: Action?
        if let url = best.url, !url.isEmpty {
            action = Action(kind: "open_in_maps", label: "Open in Maps", params: ["url": url])
        } else if let lat = best.lat, let lng = best.lng {
            action = Action(kind: "open_in_maps", label: "Open in Maps",
                            params: ["url": "https://www.google.com/maps/search/?api=1&query=\(lat),\(lng)"])
        } else { action = nil }
        return ContentOutcome(info: lines.joined(separator: "\n"), image: nil, source: nil, html: nil, action: action)
    }

    private nonisolated func preparedReplyContent(context: String, asker: String?, spoken: Language) async -> ContentOutcome {
        let who = asker ?? "the other party"
        let aids: String
        switch spoken {
        case .ja: aids = config.furigana ? "furigana ON (annotate hard kanji)" : "furigana OFF"
        case .zh: aids = config.pinyin ? "pinyin ON (annotate hard characters)" : "pinyin OFF"
        case .en: aids = "none"
        }
        let user = """
        CARD KIND: prepared_line
        Floor language: \(LookupRouter.name(spoken))
        Interface language: \(LookupRouter.name(interface))
        Reading aids: \(aids)
        Who is asking: \(who)
        Conversation context:
        \(context)
        Produce the JSON now.
        """
        guard let raw = try? await llm.complete(system: Prompts.drafter, user: user, model: config.drafterModel),
              let obj = JSONExtract.decodeObject(raw) else {
            return ContentOutcome(info: nil, image: nil, source: nil, html: nil, action: nil)
        }
        let line = (obj["line"] as? String) ?? ""
        let translation = (obj["translation"] as? String) ?? ""
        guard !line.isEmpty else { return ContentOutcome(info: nil, image: nil, source: nil, html: nil, action: nil) }
        let response = RichResponse(spoken: line, translation: translation, language: spoken,
                                    rationale: "Suggested reply for \(who). Adjust as needed.")
        return ContentOutcome(info: nil, image: nil, source: nil, html: nil, action: nil, response: response)
    }

    private nonisolated func fetchResponse(window: String, screen: String, spoken: Language) async -> RichResponse? {
        let user = """
        Spoken language: \(LookupRouter.name(spoken))
        Interface language: \(LookupRouter.name(interface))
        Conversation context (newest last):
        \(window)
        On screen now:
        \(screen.isEmpty ? "(nothing)" : screen)
        Produce the JSON now.
        """
        guard let raw = try? await withTimeout(seconds: config.onlineCapSeconds, { [llm, config] in
            try await llm.complete(system: Prompts.responder, user: user, model: config.drafterModel)
        }), let obj = JSONExtract.decodeObject(raw) else {
            Self.logReply(spoken: spoken, warranted: nil); return nil
        }
        let warranted = (obj["warranted"] as? Bool) == true
        guard warranted else { Self.logReply(spoken: spoken, warranted: false); return nil }
        let spokenText = (obj["spoken"] as? String) ?? ""
        guard !spokenText.isEmpty else { Self.logReply(spoken: spoken, warranted: true); return nil }
        Self.logReply(spoken: spoken, warranted: true)
        return RichResponse(spoken: spokenText, translation: (obj["translation"] as? String) ?? "",
                            language: spoken, rationale: (obj["rationale"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - Apply

    private func apply(_ outcome: PartOutcome, to card: inout RichCard) {
        switch outcome {
        case .content(let c, let elapsed):
            if let img = c.image { card.imageURL = img }
            if let src = c.source { card.source = src }
            if !c.sources.isEmpty { card.sources = c.sources }
            if let html = c.html { card.searchSuggestionHTML = html }
            if let action = c.action { card.action = action }
            if let resp = c.response { card.response = resp }
            if let info = c.info { card.info = info; card.unverified = c.unverified }
            else if !produced(c) && card.info == nil && card.response == nil {
                // The content genuinely returned nothing: resolve to an honest line,
                // never a fabricated answer.
                card.info = Self.noResult(interface)
            }
            card.pending.remove(RichCard.Part.info.rawValue)
            card.pending.remove(RichCard.Part.image.rawValue)
            card.pending.remove(RichCard.Part.source.rawValue)
            if c.response != nil { card.pending.remove(RichCard.Part.response.rawValue) }
            card.timings["content"] = elapsed
        case .response(let r, let elapsed):
            card.response = r
            card.pending.remove(RichCard.Part.response.rawValue)
            card.timings["response"] = elapsed
        }
    }

    private func produced(_ c: ContentOutcome) -> Bool {
        c.info != nil || c.response != nil || c.source != nil || c.image != nil || c.action != nil
    }

    private func pendingForKnowledge(plan: LookupPlan, respond: Bool) -> Set<String> {
        var p = Set<String>()
        switch plan.route {
        case .trivial: break
        case .entity:
            p.insert(RichCard.Part.info.rawValue)
            if plan.needsImage { p.insert(RichCard.Part.image.rawValue) }
            p.insert(RichCard.Part.source.rawValue)
        case .fresh, .technical:
            // Both try grounded search, which can return a source.
            p.insert(RichCard.Part.info.rawValue); p.insert(RichCard.Part.source.rawValue)
        default:
            p.insert(RichCard.Part.info.rawValue)
        }
        if respond { p.insert(RichCard.Part.response.rawValue) }
        return p
    }

    // Diagnostic for the reply path: which spoken language was used and whether the
    // responder judged a reply warranted. Set MAI_DEBUG_REPLY=1 to see it; this is how
    // to observe why a given (e.g. Japanese) utterance did or did not get a reply.
    nonisolated static func logReply(spoken: Language, warranted: Bool?) {
        guard ProcessInfo.processInfo.environment["MAI_DEBUG_REPLY"] == "1" else { return }
        let w = warranted.map { $0 ? "warranted" : "declined" } ?? "no-response"
        FileHandle.standardError.write(Data("Mai reply: spoken=\(spoken.rawValue) -> \(w)\n".utf8))
    }

    // MARK: - Small helpers

    private nonisolated func trimNum(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }

    // Only reached when even the model could not be contacted (e.g. the network is
    // down): every route falls through to a general-knowledge answer first, so this
    // is a connectivity message, not "no answer exists".
    static func noResult(_ l: Language) -> String {
        switch l {
        case .en: return "Could not reach the answer service just now; will retry on the next mention."
        case .ja: return "今は情報を取得できませんでした。次に話題に出たときに再取得します。"
        case .zh: return "暂时无法获取信息，下次提到时会再试。"
        }
    }
}

// Result of a content fetch (entity / grounded / explanation / place / prepared
// reply). Any field may be nil; a content task may also carry a response (the
// prepared-reply route puts its line here).
struct ContentOutcome: Sendable {
    var info: String?
    var image: String?
    var source: RichSource?
    var sources: [RichSource]
    var html: String?
    var action: Action?
    var response: RichResponse?
    var unverified: Bool   // model fallback with no source; the card is labeled
    init(info: String?, image: String?, source: RichSource?, html: String?, action: Action?,
         sources: [RichSource] = [], response: RichResponse? = nil, unverified: Bool = false) {
        self.info = info; self.image = image; self.source = source; self.html = html
        self.action = action; self.sources = sources; self.response = response; self.unverified = unverified
    }
}

enum PartOutcome: Sendable {
    case content(ContentOutcome, Int)
    case response(RichResponse?, Int)
}

private func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
