import Foundation

public enum MaiTraceEventKind: String, Codable, Sendable {
    case transcript
    case screen
}

public struct MaiTraceEvent: Codable, Sendable, Equatable {
    public let kind: MaiTraceEventKind
    public let offsetMs: Int
    public let speaker: String?
    public let language: String?
    public let text: String
    public let subject: String?
    public let appName: String?
    public let bundleIdentifier: String?
    public let windowTitle: String?

    public init(kind: MaiTraceEventKind, offsetMs: Int, speaker: String?, language: String?,
                text: String, subject: String? = nil, appName: String? = nil,
                bundleIdentifier: String? = nil, windowTitle: String? = nil) {
        self.kind = kind
        self.offsetMs = offsetMs
        self.speaker = speaker
        self.language = language
        self.text = text
        self.subject = subject
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
    }
}

public struct MaiTrace: Codable, Sendable, Equatable {
    public let version: Int
    public let startedAt: Date
    public let events: [MaiTraceEvent]

    public init(version: Int = 1, startedAt: Date = Date(), events: [MaiTraceEvent]) {
        self.version = version
        self.startedAt = startedAt
        self.events = events
    }

    public func input(for event: MaiTraceEvent) -> EngineInput {
        let timestamp = startedAt.addingTimeInterval(Double(event.offsetMs) / 1000)
        switch event.kind {
        case .transcript:
            return .transcript(TranscriptEvent(text: event.text, speaker: event.speaker,
                                               timestamp: timestamp, isFinal: true, language: event.language))
        case .screen:
            return .screen(ScreenContentEvent(content: event.text, timestamp: timestamp,
                                              isChange: true, subject: event.subject,
                                              appName: event.appName,
                                              bundleIdentifier: event.bundleIdentifier,
                                              windowTitle: event.windowTitle))
        }
    }

    public func encodePretty() throws -> Data {
        try JSONEncoder.prettyMai.encode(self)
    }
}

public struct GoldenCardExpectation: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let route: LookupRoute
    public let headlineContains: String?
    public let requiresSource: Bool
    public let requiresResponse: Bool
    public let minQuality: Double
    public let maxFirstPaintMs: Int

    public init(id: String, label: String, route: LookupRoute, headlineContains: String? = nil,
                requiresSource: Bool = false, requiresResponse: Bool = false,
                minQuality: Double = CardRating.usefulThreshold, maxFirstPaintMs: Int = 3000) {
        self.id = id
        self.label = label
        self.route = route
        self.headlineContains = headlineContains
        self.requiresSource = requiresSource
        self.requiresResponse = requiresResponse
        self.minQuality = minQuality
        self.maxFirstPaintMs = maxFirstPaintMs
    }
}

public struct GoldenTracePack: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let trace: MaiTrace
    public let expectations: [GoldenCardExpectation]

    public init(id: String, name: String, summary: String, trace: MaiTrace,
                expectations: [GoldenCardExpectation]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.trace = trace
        self.expectations = expectations
    }
}

public struct GoldenTraceAssertionResult: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let passed: Bool
    public let detail: String

    public init(id: String, label: String, passed: Bool, detail: String) {
        self.id = id
        self.label = label
        self.passed = passed
        self.detail = detail
    }
}

public enum GoldenTraceAssert {
    public static func evaluate(pack: GoldenTracePack, cards: [RichCard]) -> [GoldenTraceAssertionResult] {
        let resolved = cards.filter { !$0.suppressed && $0.pending.isEmpty }
        return pack.expectations.map { expectation in
            let candidates = resolved.filter { card in
                guard card.route == expectation.route else { return false }
                if let needle = expectation.headlineContains, !needle.isEmpty {
                    return card.headline.localizedCaseInsensitiveContains(needle)
                }
                return true
            }
            guard let card = candidates.first else {
                return GoldenTraceAssertionResult(id: expectation.id, label: expectation.label,
                                                  passed: false, detail: "missing \(expectation.route.rawValue) card")
            }
            if expectation.requiresSource && card.source == nil && card.sources.isEmpty {
                return GoldenTraceAssertionResult(id: expectation.id, label: expectation.label,
                                                  passed: false, detail: "card had no source")
            }
            if expectation.requiresResponse && card.response == nil {
                return GoldenTraceAssertionResult(id: expectation.id, label: expectation.label,
                                                  passed: false, detail: "card had no prepared response")
            }
            let quality = card.rating?.score ?? 0
            if quality < expectation.minQuality {
                return GoldenTraceAssertionResult(id: expectation.id, label: expectation.label,
                                                  passed: false, detail: "quality \(String(format: "%.2f", quality)) below \(String(format: "%.2f", expectation.minQuality))")
            }
            let firstPaint = card.latencyMs ?? Int.max
            if firstPaint > expectation.maxFirstPaintMs {
                return GoldenTraceAssertionResult(id: expectation.id, label: expectation.label,
                                                  passed: false, detail: "first paint \(firstPaint) ms above \(expectation.maxFirstPaintMs) ms")
            }
            return GoldenTraceAssertionResult(id: expectation.id, label: expectation.label,
                                              passed: true, detail: "matched \(card.headline)")
        }
    }
}

public enum GoldenTracePacks {
    public static let badSessionV1 = GoldenTracePack(
        id: "bad-session-v1",
        name: "Bad Session V1",
        summary: "Language switches, repeated topics, screen changes, places, fresh info, and Salesforce technical context.",
        trace: MaiTrace(startedAt: Date(timeIntervalSince1970: 1_783_204_800), events: [
            MaiTraceEvent(kind: .transcript, offsetMs: 0, speaker: "Speaker 1", language: "en", text: "okay"),
            MaiTraceEvent(kind: .screen, offsetMs: 1000, speaker: nil, language: nil,
                          text: "Synthetic Salesforce engineering screen with retries, replay IDs, dead-letter handling, and backpressure.",
                          subject: "Salesforce Platform Events replay ID recovery"),
            MaiTraceEvent(kind: .transcript, offsetMs: 2000, speaker: "Speaker 2", language: "en", text: "what's 15% of 80"),
            MaiTraceEvent(kind: .transcript, offsetMs: 3000, speaker: "Speaker 3", language: "ja", text: "ngl ちょっとお寿司食べたい"),
            MaiTraceEvent(kind: .transcript, offsetMs: 4000, speaker: "Speaker 4", language: "en", text: "what is the latest iPhone price today"),
            MaiTraceEvent(kind: .transcript, offsetMs: 5000, speaker: "Speaker 5", language: "ja", text: "それでは、ご意見をお願いできますか？"),
            MaiTraceEvent(kind: .screen, offsetMs: 6000, speaker: nil, language: nil,
                          text: "Synthetic Malaysia market expansion slide.", subject: "Malaysia"),
            MaiTraceEvent(kind: .transcript, offsetMs: 7000, speaker: "Speaker 6", language: "en",
                          text: "how should we handle Salesforce Platform Events retry failures?"),
            MaiTraceEvent(kind: .transcript, offsetMs: 8000, speaker: "Speaker 7", language: "zh", text: "你怎么看"),
            MaiTraceEvent(kind: .transcript, offsetMs: 9000, speaker: "Speaker 4", language: "en", text: "what is the latest iPhone price today"),
        ]),
        expectations: [
            GoldenCardExpectation(id: "salesforce-screen", label: "Salesforce screen card",
                                  route: .technical, headlineContains: "Salesforce", requiresSource: true),
            GoldenCardExpectation(id: "trivial-math", label: "Instant math",
                                  route: .trivial, headlineContains: "15%"),
            GoldenCardExpectation(id: "nearby-sushi", label: "Nearby sushi",
                                  route: .place, headlineContains: "sushi"),
            GoldenCardExpectation(id: "fresh-current", label: "Fresh current answer",
                                  route: .fresh, headlineContains: "iPhone", requiresSource: true),
            GoldenCardExpectation(id: "reply-ja", label: "Japanese reply",
                                  route: .preparedReply, requiresResponse: true),
            GoldenCardExpectation(id: "malaysia-screen", label: "Malaysia screen entity",
                                  route: .entity, headlineContains: "Malaysia", requiresSource: true),
        ])

    public static let all: [GoldenTracePack] = [badSessionV1]
}

public enum TraceAnonymizer {
    public static func transcript(_ event: TranscriptEvent, sessionStartedAt: Date) -> MaiTraceEvent? {
        guard event.isFinal else { return nil }
        let offset = max(0, Int(event.timestamp.timeIntervalSince(sessionStartedAt) * 1000))
        return MaiTraceEvent(kind: .transcript, offsetMs: offset,
                             speaker: anonymizedSpeaker(event.speaker),
                             language: event.language,
                             text: sanitizedTranscript(event.text))
    }

    public static func screen(_ event: ScreenContentEvent, sessionStartedAt: Date) -> MaiTraceEvent {
        let offset = max(0, Int(event.timestamp.timeIntervalSince(sessionStartedAt) * 1000))
        let sanitizedSubject = event.subject.map(sanitizedSubject)
        return MaiTraceEvent(kind: .screen, offsetMs: offset,
                             speaker: nil, language: nil,
                             text: sanitizedScreen(event.content, subject: sanitizedSubject),
                             subject: sanitizedSubject,
                             appName: sanitizedAppName(event.appName, bundleIdentifier: event.bundleIdentifier),
                             bundleIdentifier: sanitizedBundleIdentifier(event.bundleIdentifier),
                             windowTitle: sanitizedWindowTitle(event.windowTitle, appName: event.appName))
    }

    public static func sanitizedTranscript(_ text: String) -> String {
        let low = text.lowercased()
        if TrivialAnswer.answer(text) != nil { return "what's 15% of 80" }
        if low.contains("sushi") || text.contains("寿司") { return "I want sushi nearby" }
        if low.contains("ramen") || text.contains("ラーメン") { return "I want ramen nearby" }
        if low.contains("coffee") || text.contains("カフェ") { return "I want coffee nearby" }
        if low.contains("latest") || low.contains("today") || low.contains("price")
            || text.contains("最新") || text.contains("天気") { return "what is the latest iPhone price today" }
        if low.contains("what do you think") || text.contains("ご意見") || text.contains("どう思います")
            || text.contains("你怎么看") { return text.contains("ご") || text.contains("どう") ? "それでは、ご意見をお願いできますか？" : "what do you think about the plan?" }
        if low.contains("screen") || text.contains("画面") || text.contains("スライド") { return "please look at the screen" }
        if low.contains("salesforce") || low.contains("queueable") || low.contains("platform event") {
            return "how should we handle Salesforce Platform Events retry failures?"
        }
        if low.contains("malaysia") || text.contains("マレーシア") || text.contains("马来西亚") { return "we are discussing Malaysia" }
        if low.contains("pudding") || text.contains("プリン") { return "how do I make pudding?" }
        if low == "ok" || low == "okay" || text == "ありがとうございます" { return low.isEmpty ? "okay" : text }
        return "okay"
    }

    public static func sanitizedScreen(_ text: String, subject: String?) -> String {
        if let subject, !subject.isEmpty { return "Synthetic screen about \(subject)." }
        let low = text.lowercased()
        if low.contains("salesforce") || low.contains("queueable") || low.contains("platform event") {
            return "Synthetic Salesforce engineering screen with retries, replay IDs, dead-letter handling, and backpressure."
        }
        if low.contains("revenue") { return "Synthetic revenue overview slide." }
        if low.contains("malaysia") { return "Synthetic Malaysia market expansion slide." }
        return "Synthetic screen with no private text."
    }

    public static func sanitizedSubject(_ subject: String) -> String {
        let low = subject.lowercased()
        if low.contains("salesforce") { return "Salesforce Platform Events replay ID recovery" }
        if low.contains("malaysia") || subject.contains("マレーシア") || subject.contains("马来西亚") { return "Malaysia" }
        if low.contains("revenue") { return "Q3 Revenue Overview" }
        if subject.contains("寿司") || low.contains("sushi") { return "Sushi" }
        return "Synthetic Topic"
    }

    public static func sanitizedAppName(_ appName: String?, bundleIdentifier: String?) -> String? {
        let haystack = "\(appName ?? "") \(bundleIdentifier ?? "")".lowercased()
        if haystack.contains("xcode") || haystack.contains("visual studio") || haystack.contains("code") { return "Code Editor" }
        if haystack.contains("safari") || haystack.contains("chrome") || haystack.contains("firefox") { return "Browser" }
        if haystack.contains("salesforce") { return "CRM" }
        if haystack.contains("terminal") || haystack.contains("iterm") { return "Terminal" }
        if haystack.contains("slack") || haystack.contains("teams") || haystack.contains("zoom") { return "Meeting or Chat" }
        if appName?.isEmpty == false { return "App" }
        return nil
    }

    public static func sanitizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let low = bundleIdentifier.lowercased()
        if low.contains("xcode") || low.contains("code") { return "dev.code-editor" }
        if low.contains("safari") || low.contains("chrome") || low.contains("firefox") { return "web.browser" }
        if low.contains("terminal") || low.contains("iterm") { return "dev.terminal" }
        if low.contains("slack") || low.contains("teams") || low.contains("zoom") { return "meeting.chat" }
        return "app.redacted"
    }

    public static func sanitizedWindowTitle(_ windowTitle: String?, appName: String?) -> String? {
        guard let windowTitle, !windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let low = "\(windowTitle) \(appName ?? "")".lowercased()
        if low.contains(".swift") { return "Swift source file" }
        if low.contains("salesforce") { return "Salesforce workspace" }
        if low.contains("calendar") { return "Calendar window" }
        if low.contains("terminal") { return "Terminal window" }
        return "Window title redacted"
    }

    private static func anonymizedSpeaker(_ speaker: String?) -> String? {
        guard let speaker, !speaker.isEmpty else { return nil }
        let seed = speaker.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let bucket = abs(seed % 8) + 1
        return "Speaker \(bucket)"
    }
}

public struct SyntheticSoakReport: Codable, Sendable, Equatable {
    public let durationMinutes: Int
    public let eventCount: Int
    public let resolvedCards: Int
    public let suppressedCards: Int
    public let weakCards: Int
    public let maxFirstPaintMs: Int
    public let maxFinalFillMs: Int
    public let routeCounts: [String: Int]
    public let notes: [String]
}

public enum SyntheticSoak {
    public static func trace(durationMinutes: Int = 30, startedAt: Date = Date()) -> MaiTrace {
        trace(durationSeconds: max(60, durationMinutes * 60), startedAt: startedAt)
    }

    public static func trace(durationSeconds: Int, startedAt: Date = Date()) -> MaiTrace {
        let totalSeconds = max(1, durationSeconds)
        let interval = totalSeconds < 120 ? 2 : 12
        var events: [MaiTraceEvent] = []
        var offset = 0
        var i = 0
        while offset <= totalSeconds * 1000 {
            switch i % 16 {
            case 0, 1, 7, 11:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 1",
                                            language: "en", text: "okay"))
            case 2:
                events.append(MaiTraceEvent(kind: .screen, offsetMs: offset, speaker: nil,
                                            language: nil,
                                            text: "Synthetic Salesforce engineering screen with retries and replay IDs.",
                                            subject: "Salesforce Platform Events replay ID recovery"))
            case 3:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 2",
                                            language: "en", text: "what's 15% of 80"))
            case 4:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 3",
                                            language: "ja", text: "ngl ちょっとお寿司食べたい"))
            case 5:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 4",
                                            language: "en", text: "what is the latest iPhone price today"))
            case 6:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 5",
                                            language: "ja", text: "それでは、ご意見をお願いできますか？"))
            case 8:
                events.append(MaiTraceEvent(kind: .screen, offsetMs: offset, speaker: nil,
                                            language: nil, text: "Synthetic Malaysia market expansion slide.",
                                            subject: "Malaysia"))
            case 9:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 2",
                                            language: "en", text: "I want sushi nearby"))
            case 10:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 1",
                                            language: "en", text: "how do I make pudding?"))
            case 12:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 6",
                                            language: "zh", text: "你怎么看"))
            case 13:
                events.append(MaiTraceEvent(kind: .screen, offsetMs: offset, speaker: nil,
                                            language: nil, text: "Synthetic revenue overview slide.",
                                            subject: "Q3 Revenue Overview"))
            case 14:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 7",
                                            language: "en", text: "how should we handle Salesforce Platform Events retry failures?"))
            default:
                events.append(MaiTraceEvent(kind: .transcript, offsetMs: offset, speaker: "Speaker 8",
                                            language: "ja", text: "ありがとうございます"))
            }
            i += 1
            offset += interval * 1000
        }
        return MaiTrace(startedAt: startedAt, events: events)
    }

    public static func report(cards: [RichCard], durationMinutes: Int, eventCount: Int) -> SyntheticSoakReport {
        let resolved = cards.filter { $0.pending.isEmpty && !$0.suppressed }
        let suppressed = cards.filter(\.suppressed)
        var routeCounts: [String: Int] = [:]
        for card in resolved { routeCounts[card.route.rawValue, default: 0] += 1 }
        let maxFirst = resolved.compactMap(\.latencyMs).max() ?? 0
        let maxFinal = resolved.map { $0.telemetry.finalFillMs ?? 0 }.max() ?? 0
        let weak = cards.filter { $0.rating?.useful == false }.count
        var notes: [String] = []
        if maxFirst > 3000 { notes.append("normal first-paint latency exceeded 3s") }
        if weak > 0 { notes.append("\(weak) card(s) rated weak") }
        if resolved.isEmpty { notes.append("no cards resolved") }
        if notes.isEmpty { notes.append("soak completed without local drift signals") }
        return SyntheticSoakReport(durationMinutes: durationMinutes,
                                   eventCount: eventCount,
                                   resolvedCards: resolved.count,
                                   suppressedCards: suppressed.count,
                                   weakCards: weak,
                                   maxFirstPaintMs: maxFirst,
                                   maxFinalFillMs: maxFinal,
                                   routeCounts: routeCounts,
                                   notes: notes)
    }
}
