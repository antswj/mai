import Foundation

// Configuration and secrets loading. Kept dependency-free: a tiny TOML subset
// parser (sections, string/number/bool/string-array values, # comments) and a
// simple .env reader. Both fall back to sensible defaults so tests can run with
// no files present.

public struct Config: Sendable {
    public var llmProvider: String
    public var placesProvider: String
    public var classifierModel: String
    public var drafterModel: String
    public var screenModel: String
    public var targetSeconds: Double
    public var hardCapSeconds: Double
    public var maxTurns: Int
    public var maxSeconds: Double
    public var threshold: Double
    public var showSuppressedLog: Bool
    public var refireCooldownSeconds: Double
    public var enabledTriggers: [String]
    public var interfaceLanguage: Language
    public var floorLanguage: Language
    public var meetingMode: Bool
    public var furigana: Bool
    public var pinyin: Bool
    public var screenChangeThreshold: Double
    public var screenAlwaysOn: Bool
    public var testLat: Double
    public var testLng: Double
    // Step 2: real capture settings.
    public var sttModel: String
    public var sttSampleRate: Int
    public var sttLanguageHints: [String]
    public var sttLanguageId: Bool
    public var sttDiarization: Bool
    public var sttTranslation: Bool
    public var screenSettleSeconds: Double
    public var screenFrameIntervalSeconds: Double
    public var captureSource: String
    public var startPaused: Bool
    public var showLiveTranscript: Bool
    public var ruby: Bool
    // Step 3: card intelligence (lookup router), the response toggle, latency caps,
    // and on-device voice-activity gating.
    public var lookupEnabled: Bool
    public var lookupRouterModel: String
    public var responseEnabled: Bool
    public var onlineCapSeconds: Double
    public var vadEnabled: Bool
    public var vadEngine: String
    public var vadSilenceHangoverSeconds: Double
    public var vadPrerollSeconds: Double
    public var vadOnset: Double
    public var vadOffset: Double

    public init(
        llmProvider: String = "anthropic",
        placesProvider: String = "merged",
        classifierModel: String = "claude-haiku-4-5",
        drafterModel: String = "claude-sonnet-4-6",
        screenModel: String = "gemini-2.5-flash",
        targetSeconds: Double = 3,
        hardCapSeconds: Double = 5,
        maxTurns: Int = 12,
        maxSeconds: Double = 120,
        threshold: Double = 0.6,
        showSuppressedLog: Bool = true,
        refireCooldownSeconds: Double = 90,
        enabledTriggers: [String] = ["place", "question", "intent", "reference", "screenReference"],
        interfaceLanguage: Language = .en,
        floorLanguage: Language = .ja,
        meetingMode: Bool = true,
        furigana: Bool = true,
        pinyin: Bool = true,
        screenChangeThreshold: Double = 0.15,
        screenAlwaysOn: Bool = true,
        testLat: Double = 35.7016,
        testLng: Double = 139.9853,
        sttModel: String = "stt-rt-v5",
        sttSampleRate: Int = 16000,
        sttLanguageHints: [String] = ["en", "ja", "zh"],
        sttLanguageId: Bool = true,
        sttDiarization: Bool = true,
        sttTranslation: Bool = false,
        screenSettleSeconds: Double = 1.0,
        screenFrameIntervalSeconds: Double = 1.0,
        captureSource: String = "main_display",
        startPaused: Bool = false,
        showLiveTranscript: Bool = true,
        ruby: Bool = true,
        lookupEnabled: Bool = true,
        lookupRouterModel: String = "claude-haiku-4-5",
        responseEnabled: Bool = false,
        onlineCapSeconds: Double = 5,
        vadEnabled: Bool = true,
        vadEngine: String = "silero_v5",
        vadSilenceHangoverSeconds: Double = 4,
        vadPrerollSeconds: Double = 1.0,
        vadOnset: Double = 0.5,
        vadOffset: Double = 0.35
    ) {
        self.llmProvider = llmProvider; self.placesProvider = placesProvider
        self.classifierModel = classifierModel; self.drafterModel = drafterModel; self.screenModel = screenModel
        self.targetSeconds = targetSeconds; self.hardCapSeconds = hardCapSeconds
        self.maxTurns = maxTurns; self.maxSeconds = maxSeconds
        self.threshold = threshold; self.showSuppressedLog = showSuppressedLog
        self.refireCooldownSeconds = refireCooldownSeconds; self.enabledTriggers = enabledTriggers
        self.interfaceLanguage = interfaceLanguage; self.floorLanguage = floorLanguage
        self.meetingMode = meetingMode; self.furigana = furigana; self.pinyin = pinyin
        self.screenChangeThreshold = screenChangeThreshold; self.screenAlwaysOn = screenAlwaysOn
        self.testLat = testLat; self.testLng = testLng
        self.sttModel = sttModel; self.sttSampleRate = sttSampleRate; self.sttLanguageHints = sttLanguageHints
        self.sttLanguageId = sttLanguageId; self.sttDiarization = sttDiarization; self.sttTranslation = sttTranslation
        self.screenSettleSeconds = screenSettleSeconds; self.screenFrameIntervalSeconds = screenFrameIntervalSeconds
        self.captureSource = captureSource; self.startPaused = startPaused
        self.showLiveTranscript = showLiveTranscript; self.ruby = ruby
        self.lookupEnabled = lookupEnabled; self.lookupRouterModel = lookupRouterModel
        self.responseEnabled = responseEnabled; self.onlineCapSeconds = onlineCapSeconds
        self.vadEnabled = vadEnabled; self.vadEngine = vadEngine
        self.vadSilenceHangoverSeconds = vadSilenceHangoverSeconds; self.vadPrerollSeconds = vadPrerollSeconds
        self.vadOnset = vadOnset; self.vadOffset = vadOffset
    }

    /// Load from a config.toml. Missing file or missing keys fall back to defaults.
    public static func load(path: String = "config.toml") -> Config {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Config()
        }
        let toml = TOML.parse(text)
        var c = Config()
        func str(_ s: String, _ k: String) -> String? { toml[s]?[k]?.string }
        func dbl(_ s: String, _ k: String) -> Double? { toml[s]?[k]?.double }
        func bln(_ s: String, _ k: String) -> Bool? { toml[s]?[k]?.bool }
        if let v = str("providers", "llm") { c.llmProvider = v }
        if let v = str("providers", "places") { c.placesProvider = v }
        if let v = str("models", "classifier") { c.classifierModel = v }
        if let v = str("models", "drafter") { c.drafterModel = v }
        if let v = str("models", "screen") { c.screenModel = v }
        if let v = dbl("latency", "target_seconds") { c.targetSeconds = v }
        if let v = dbl("latency", "hard_cap_seconds") { c.hardCapSeconds = v }
        if let v = dbl("rolling_context", "max_turns") { c.maxTurns = Int(v) }
        if let v = dbl("rolling_context", "max_seconds") { c.maxSeconds = v }
        if let v = dbl("surfacing", "threshold") { c.threshold = v }
        if let v = bln("surfacing", "show_suppressed_log") { c.showSuppressedLog = v }
        if let v = dbl("surfacing", "refire_cooldown_seconds") { c.refireCooldownSeconds = v }
        if let v = toml["triggers"]?["enabled"]?.stringArray { c.enabledTriggers = v }
        if let v = str("language", "interface"), let l = Language(rawValue: v) { c.interfaceLanguage = l }
        if let v = str("language", "floor"), let l = Language(rawValue: v) { c.floorLanguage = l }
        if let v = bln("language", "meeting_mode") { c.meetingMode = v }
        if let v = bln("language", "furigana") { c.furigana = v }
        if let v = bln("language", "pinyin") { c.pinyin = v }
        if let v = dbl("screen", "change_threshold") { c.screenChangeThreshold = v }
        if let v = bln("screen", "always_on") { c.screenAlwaysOn = v }
        if let v = dbl("location", "test_lat") { c.testLat = v }
        if let v = dbl("location", "test_lng") { c.testLng = v }
        // Step 2 sections.
        if let v = str("stt", "model") { c.sttModel = v }
        if let v = dbl("stt", "sample_rate") { c.sttSampleRate = Int(v) }
        if let v = toml["stt"]?["language_hints"]?.stringArray { c.sttLanguageHints = v }
        if let v = bln("stt", "enable_language_identification") { c.sttLanguageId = v }
        if let v = bln("stt", "enable_speaker_diarization") { c.sttDiarization = v }
        if let v = bln("stt", "translation") { c.sttTranslation = v }
        if let v = str("vision", "model") { c.screenModel = v }  // Gemini vision model for screen reads
        if let v = dbl("screen", "settle_seconds") { c.screenSettleSeconds = v }
        if let v = dbl("screen", "frame_interval_seconds") { c.screenFrameIntervalSeconds = v }
        if let v = str("screen", "capture_source") { c.captureSource = v }
        if let v = bln("capture", "start_paused") { c.startPaused = v }
        if let v = bln("transcript", "show_live") { c.showLiveTranscript = v }
        if let v = bln("transcript", "ruby") { c.ruby = v }
        // Step 3 sections.
        if let v = bln("lookup", "enabled") { c.lookupEnabled = v }
        if let v = str("lookup", "router_model") { c.lookupRouterModel = v }
        if let v = str("models", "router") { c.lookupRouterModel = v }
        if let v = bln("response", "enabled") { c.responseEnabled = v }
        if let v = dbl("latency", "online_cap_seconds") { c.onlineCapSeconds = v }
        if let v = bln("vad", "enabled") { c.vadEnabled = v }
        if let v = str("vad", "engine") { c.vadEngine = v }
        if let v = dbl("vad", "silence_hangover_seconds") { c.vadSilenceHangoverSeconds = v }
        if let v = dbl("vad", "preroll_seconds") { c.vadPrerollSeconds = v }
        if let v = dbl("vad", "onset") { c.vadOnset = v }
        if let v = dbl("vad", "offset") { c.vadOffset = v }
        return c
    }
}

// Secrets, loaded from .env (KEY=VALUE per line) with the process environment as
// a fallback. Never logged, never written anywhere.
public struct Secrets: Sendable {
    private let values: [String: String]
    public init(path: String = ".env") {
        var v: [String: String] = [:]
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    val = String(val.dropFirst().dropLast())
                }
                v[key] = val
            }
        }
        self.values = v
    }
    public init(values: [String: String]) { self.values = values }
    public func get(_ key: String) -> String? {
        if let v = values[key], !v.isEmpty { return v }
        if let e = ProcessInfo.processInfo.environment[key], !e.isEmpty { return e }
        return nil
    }
}

// Minimal TOML subset parser. Handles enough for config.toml.
enum TOMLValue: Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([String])
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var stringArray: [String]? { if case .array(let a) = self { return a }; return nil }
}

enum TOML {
    static func parse(_ text: String) -> [String: [String: TOMLValue]] {
        var result: [String: [String: TOMLValue]] = [:]
        var section = ""
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") {
                // strip trailing comment (config.toml has no '#' inside string values)
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if result[section] == nil { result[section] = [:] }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let rhs = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            result[section, default: [:]][key] = parseValue(rhs)
        }
        return result
    }

    private static func parseValue(_ s: String) -> TOMLValue {
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let inner = String(s.dropFirst().dropLast())
            let parts = inner.split(separator: ",").map { p -> String in
                var t = p.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 { t = String(t.dropFirst().dropLast()) }
                return t
            }.filter { !$0.isEmpty }
            return .array(parts)
        }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 {
            return .string(String(s.dropFirst().dropLast()))
        }
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if let n = Double(s) { return .number(n) }
        return .string(s)
    }
}
