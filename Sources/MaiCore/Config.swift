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
    public var sttTranslation: Bool          // live-transcript translation toggle (default off)
    public var translationEngine: String     // which TranslationProvider ("soniox" now)
    public var screenSettleSeconds: Double
    public var screenFrameIntervalSeconds: Double
    public var captureSource: String
    public var startPaused: Bool
    public var sessionAutoRollover: Bool
    public var sessionIdleRolloverSeconds: Double
    public var sessionMaxSeconds: Double
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
    // Live coaching. The fast local coach stays instant; the AI coach is allowed to
    // take longer and uses vocal features extracted from real audio.
    public var coachingAIEnabled: Bool
    public var coachingAIModel: String
    public var coachingAICapSeconds: Double
    public var coachingAIMinIntervalSeconds: Double
    // Ambient Conversation Focus: a consent-gated sensitivity profile for noisy,
    // nearby consented conversation. It lowers speech thresholds and rejects steady
    // music/noise beds, but does not authorize covert recording.
    public var ambientConversationFocus: Bool
    public var ambientConsentConfirmed: Bool
    public var ambientMusicRejection: Bool
    public var ambientVadOnset: Double
    public var ambientVadOffset: Double
    public var ambientSpeechRMSThreshold: Double
    // Echo suppression (mic picking up speaker output). hold = how long a mic final is
    // held when system audio is active, so a matching system final can be compared
    // regardless of which stream finalizes first.
    public var echoSuppression: Bool
    // RMS threshold (0..1) above which system audio counts as "the speaker is playing",
    // used to detect mic/speaker concurrency (acoustic echo). Raise it if quiet
    // background media wrongly suppresses your speech; lower it if echo slips through.
    public var echoSystemActiveRMS: Double

    public init(
        llmProvider: String = "anthropic",
        placesProvider: String = "merged",
        classifierModel: String = "claude-haiku-4-5",
        drafterModel: String = "claude-sonnet-4-6",
        screenModel: String = "gemini-2.5-flash",
        targetSeconds: Double = 3,
        hardCapSeconds: Double = 3,
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
        translationEngine: String = "soniox",
        screenSettleSeconds: Double = 1.0,
        screenFrameIntervalSeconds: Double = 1.0,
        captureSource: String = "main_display",
        startPaused: Bool = false,
        sessionAutoRollover: Bool = true,
        sessionIdleRolloverSeconds: Double = 20 * 60,
        sessionMaxSeconds: Double = 4 * 60 * 60,
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
        vadOffset: Double = 0.35,
        coachingAIEnabled: Bool = true,
        coachingAIModel: String = "claude-haiku-4-5",
        coachingAICapSeconds: Double = 12,
        coachingAIMinIntervalSeconds: Double = 45,
        ambientConversationFocus: Bool = false,
        ambientConsentConfirmed: Bool = false,
        ambientMusicRejection: Bool = true,
        ambientVadOnset: Double = 0.35,
        ambientVadOffset: Double = 0.25,
        ambientSpeechRMSThreshold: Double = 0.008,
        echoSuppression: Bool = true,
        echoSystemActiveRMS: Double = 0.015
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
        self.translationEngine = translationEngine
        self.screenSettleSeconds = screenSettleSeconds; self.screenFrameIntervalSeconds = screenFrameIntervalSeconds
        self.captureSource = captureSource; self.startPaused = startPaused
        self.sessionAutoRollover = sessionAutoRollover
        self.sessionIdleRolloverSeconds = sessionIdleRolloverSeconds
        self.sessionMaxSeconds = sessionMaxSeconds
        self.showLiveTranscript = showLiveTranscript; self.ruby = ruby
        self.lookupEnabled = lookupEnabled; self.lookupRouterModel = lookupRouterModel
        self.responseEnabled = responseEnabled; self.onlineCapSeconds = onlineCapSeconds
        self.vadEnabled = vadEnabled; self.vadEngine = vadEngine
        self.vadSilenceHangoverSeconds = vadSilenceHangoverSeconds; self.vadPrerollSeconds = vadPrerollSeconds
        self.vadOnset = vadOnset; self.vadOffset = vadOffset
        self.coachingAIEnabled = coachingAIEnabled
        self.coachingAIModel = coachingAIModel
        self.coachingAICapSeconds = coachingAICapSeconds
        self.coachingAIMinIntervalSeconds = coachingAIMinIntervalSeconds
        self.ambientConversationFocus = ambientConversationFocus
        self.ambientConsentConfirmed = ambientConsentConfirmed
        self.ambientMusicRejection = ambientMusicRejection
        self.ambientVadOnset = ambientVadOnset
        self.ambientVadOffset = ambientVadOffset
        self.ambientSpeechRMSThreshold = ambientSpeechRMSThreshold
        self.echoSuppression = echoSuppression
        self.echoSystemActiveRMS = echoSystemActiveRMS
    }

    public var ambientFocusActive: Bool {
        ambientConversationFocus && ambientConsentConfirmed
    }

    public var audioFocusAdjusted: Config {
        guard ambientFocusActive else { return self }
        var c = self
        c.vadOnset = min(c.vadOnset, c.ambientVadOnset)
        c.vadOffset = min(c.vadOffset, c.ambientVadOffset)
        c.vadPrerollSeconds = max(c.vadPrerollSeconds, 1.5)
        c.echoSystemActiveRMS = min(c.echoSystemActiveRMS, c.ambientSpeechRMSThreshold)
        return c
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
        if let v = str("stt", "translation_engine") { c.translationEngine = v }
        if let v = str("vision", "model") { c.screenModel = v }  // Gemini vision model for screen reads
        if let v = dbl("screen", "settle_seconds") { c.screenSettleSeconds = v }
        if let v = dbl("screen", "frame_interval_seconds") { c.screenFrameIntervalSeconds = v }
        if let v = str("screen", "capture_source") { c.captureSource = v }
        if let v = bln("capture", "start_paused") { c.startPaused = v }
        if let v = bln("session", "auto_rollover") { c.sessionAutoRollover = v }
        if let v = dbl("session", "idle_rollover_seconds") { c.sessionIdleRolloverSeconds = v }
        if let v = dbl("session", "max_seconds") { c.sessionMaxSeconds = v }
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
        if let v = bln("coaching", "ai_enabled") { c.coachingAIEnabled = v }
        if let v = str("coaching", "ai_model") { c.coachingAIModel = v }
        if let v = dbl("coaching", "ai_cap_seconds") { c.coachingAICapSeconds = v }
        if let v = dbl("coaching", "ai_min_interval_seconds") { c.coachingAIMinIntervalSeconds = v }
        if let v = bln("ambient", "conversation_focus") { c.ambientConversationFocus = v }
        if let v = bln("ambient", "consent_confirmed") { c.ambientConsentConfirmed = v }
        if let v = bln("ambient", "music_rejection") { c.ambientMusicRejection = v }
        if let v = dbl("ambient", "vad_onset") { c.ambientVadOnset = v }
        if let v = dbl("ambient", "vad_offset") { c.ambientVadOffset = v }
        if let v = dbl("ambient", "speech_rms_threshold") { c.ambientSpeechRMSThreshold = v }
        if let v = bln("echo", "suppression") { c.echoSuppression = v }
        if let v = dbl("echo", "system_active_rms") { c.echoSystemActiveRMS = v }
        return c
    }
}

// Secrets, loaded from .env (KEY=VALUE per line) with the process environment as
// a fallback. Never logged, never written anywhere.
public struct Secrets: Sendable {
    private let values: [String: String]
    private let useKeychain: Bool
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
        self.useKeychain = true
    }
    public init(values: [String: String]) { self.values = values; self.useKeychain = false }
    // Resolution order: a dev .env / process env first (so local runs keep working),
    // then the Keychain (the shipped app stores user-entered keys there via Settings).
    public func get(_ key: String) -> String? {
        if let v = values[key], !v.isEmpty { return v }
        if let e = ProcessInfo.processInfo.environment[key], !e.isEmpty { return e }
        if useKeychain, let k = try? Keychain.read(account: key), !k.isEmpty { return k }
        return nil
    }
    /// The standard key names Mai uses, for the onboarding/settings key entry screen.
    public static let knownKeys = ["ANTHROPIC_API_KEY", "GEMINI_API_KEY", "SONIOX_API_KEY",
                                   "GOOGLE_PLACES_API_KEY", "HOTPEPPER_API_KEY", "GROQ_API_KEY"]
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
            var line = stripComment(String(rawLine))
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

    private static func stripComment(_ line: String) -> String {
        var out = ""
        var quote: Character?
        var escaping = false
        for ch in line {
            if let q = quote {
                out.append(ch)
                if q == "\"", ch == "\\", !escaping {
                    escaping = true
                    continue
                }
                if ch == q, !escaping { quote = nil }
                escaping = false
            } else if ch == "\"" || ch == "'" {
                quote = ch
                out.append(ch)
            } else if ch == "#" {
                break
            } else {
                out.append(ch)
            }
        }
        return out
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
