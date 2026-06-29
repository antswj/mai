import Foundation

// Local, aggregate-only usage accounting for the spend meter. Stores counts, never
// content, never telemetry. Transcription is measured in audio-seconds actually
// streamed (so VAD gating's savings during silence show up directly); the other
// services are counted per call. The dollar figure is an ESTIMATE from a rate table.

public struct UsageRates: Sendable, Equatable {
    public var transcriptionPerHour: Double   // Soniox real-time, ~$0.12/hr (confirmed 2026-06)
    public var visionPerCall: Double          // Gemini Flash screen read
    public var modelPerCall: Double           // LLM completion (classifier/drafter/assistant/notes)
    public var searchPerCall: Double          // Gemini grounded web search
    public init(transcriptionPerHour: Double = 0.12, visionPerCall: Double = 0.0004,
                modelPerCall: Double = 0.002, searchPerCall: Double = 0.002) {
        self.transcriptionPerHour = transcriptionPerHour; self.visionPerCall = visionPerCall
        self.modelPerCall = modelPerCall; self.searchPerCall = searchPerCall
    }
}

public struct UsageCounts: Sendable, Codable, Equatable {
    public var date: String                   // yyyy-MM-dd
    public var transcriptionSeconds: Double
    public var visionCalls: Int
    public var modelCalls: Int
    public var searchCalls: Int
    public init(date: String, transcriptionSeconds: Double = 0, visionCalls: Int = 0,
                modelCalls: Int = 0, searchCalls: Int = 0) {
        self.date = date; self.transcriptionSeconds = transcriptionSeconds
        self.visionCalls = visionCalls; self.modelCalls = modelCalls; self.searchCalls = searchCalls
    }
}

public struct SpendEstimate: Sendable, Equatable {
    public var transcription: Double
    public var vision: Double
    public var model: Double
    public var search: Double
    public var total: Double
}

// Pure, deterministic spend math (unit-tested).
public enum SpendMath {
    public static func estimate(_ c: UsageCounts, rates r: UsageRates) -> SpendEstimate {
        let t = c.transcriptionSeconds / 3600.0 * r.transcriptionPerHour
        let v = Double(c.visionCalls) * r.visionPerCall
        let m = Double(c.modelCalls) * r.modelPerCall
        let s = Double(c.searchCalls) * r.searchPerCall
        return SpendEstimate(transcription: t, vision: v, model: m, search: s, total: t + v + m + s)
    }
}

// The live counter. Aggregates today's counts in memory and persists them per day to
// a small JSON file. Concurrency-safe (an actor); record calls are cheap.
public actor UsageMeter {
    private let storeURL: URL?
    private var counts: UsageCounts
    private let dayKey: @Sendable () -> String

    public init(storeURL: URL? = nil, dayKey: @escaping @Sendable () -> String = UsageMeter.today) {
        self.storeURL = storeURL
        self.dayKey = dayKey
        let today = dayKey()
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([String: UsageCounts].self, from: data),
           let c = saved[today] {
            self.counts = c
        } else {
            self.counts = UsageCounts(date: today)
        }
    }

    public func recordTranscription(seconds: Double) { counts.transcriptionSeconds += max(0, seconds); persist() }
    public func recordVision() { counts.visionCalls += 1; persist() }
    public func recordModel() { counts.modelCalls += 1; persist() }
    public func recordSearch() { counts.searchCalls += 1; persist() }

    public func snapshot() -> UsageCounts { rolloverIfNeeded(); return counts }

    private func rolloverIfNeeded() {
        let today = dayKey()
        if counts.date != today { counts = UsageCounts(date: today) }
    }

    private func persist() {
        rolloverIfNeeded()
        guard let storeURL else { return }
        var all: [String: UsageCounts] = [:]
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([String: UsageCounts].self, from: data) {
            all = saved
        }
        all[counts.date] = counts
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try? enc.encode(all).write(to: storeURL, options: .atomic)
    }

    public static let today: @Sendable () -> String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// Wraps any LLMProvider to count model calls toward the spend meter. Other providers
// (grounded search, vision) take the meter directly.
public struct MeteredLLM: LLMProvider {
    private let wrapped: LLMProvider
    private let meter: UsageMeter
    public init(_ wrapped: LLMProvider, meter: UsageMeter) { self.wrapped = wrapped; self.meter = meter }
    public func complete(system: String, user: String, model: String) async throws -> String {
        await meter.recordModel()
        return try await wrapped.complete(system: system, user: user, model: model)
    }
}
