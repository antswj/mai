import Foundation

// Soniox real-time protocol: the config message, the token/message shapes, and a
// pure segmenter that turns the token stream into finalized utterances (for the
// engine) plus a live line (for the transcript view). Verified against the live
// Soniox docs 2026-06 (model stt-rt-v5, audio_format pcm_s16le, per-token is_final,
// language, speaker; <end>/<fin> markers; {finished:true} terminator).

public struct SonioxToken: Codable, Sendable {
    public let text: String
    public let isFinal: Bool?
    public let speaker: String?
    public let language: String?
    public let translationStatus: String?
    public let startMs: Int?
    public let endMs: Int?
    public let confidence: Double?
    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
        case speaker
        case language
        case translationStatus = "translation_status"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case confidence
    }
    public var isEndpointMarker: Bool { text == "<end>" || text == "<fin>" }
}

public struct SonioxMessage: Codable, Sendable {
    public let tokens: [SonioxToken]?
    public let finished: Bool?
    public let errorCode: Int?
    public let errorType: String?
    public let errorMessage: String?
    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
    }
    public static func parse(_ data: Data) -> SonioxMessage? {
        try? JSONDecoder().decode(SonioxMessage.self, from: data)
    }
    public static func parse(_ text: String) -> SonioxMessage? {
        guard let d = text.data(using: .utf8) else { return nil }
        return parse(d)
    }
}

// The first text frame: stream configuration. api_key travels here, not in a header.
public enum SonioxConfig {
    public static func json(apiKey: String, model: String, sampleRate: Int, channels: Int,
                            languageHints: [String], languageId: Bool, diarization: Bool,
                            translationTarget: String?) -> String {
        var dict: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": channels,
            "language_hints": languageHints,
            "enable_language_identification": languageId,
            "enable_speaker_diarization": diarization,
            "enable_endpoint_detection": true,
        ]
        if let target = translationTarget {
            dict["translation"] = ["type": "one_way", "target_language": target]
        }
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// Reconnect backoff for the Soniox socket: a meeting can have long silences (the
// server closes after 3 minutes of no audio) and networks blip, so the client
// reconnects with a capped exponential backoff. Pure, so it is unit-tested.
public enum SonioxBackoff {
    public static func delaySeconds(attempt: Int, base: Double = 0.5, cap: Double = 20) -> Double {
        guard attempt > 0 else { return base }
        return min(cap, base * pow(2.0, Double(attempt - 1)))
    }
}

// A finalized utterance: original spoken text, the raw diarization speaker label
// (resolved to a display name elsewhere), and the dominant language.
public struct SonioxSegment: Sendable, Equatable {
    public let text: String
    public let speakerLabel: String?
    public let language: String?
    // The interface-language translation that rode the same stream (Soniox one-way
    // translation), when translation is enabled. nil when off. Best-effort per segment:
    // translation tokens lag the originals and may straddle the endpoint marker, so a
    // boundary chunk can be slightly off; the translation is a helper line, not a record.
    public let translation: String?
    public init(text: String, speakerLabel: String?, language: String?, translation: String? = nil) {
        self.text = text; self.speakerLabel = speakerLabel; self.language = language; self.translation = translation
    }
}

// Pure, deterministic. Feed it parsed messages; it accumulates final tokens into the
// current line, flushes a segment on an endpoint marker or a speaker change, and
// reports the live (committed + partial) line for the UI. No I/O, fully testable.
public final class SonioxSegmenter {
    private var finalText = ""
    private var speaker: String?
    private var language: String?
    // Translation accumulators (Soniox one-way translation rides the same stream, tagged
    // translation_status == "translation"). Translation tokens lag the originals and may
    // arrive after the endpoint marker, so the final translation is paired best-effort
    // with the original segment that just closed.
    private var translationFinal = ""

    public init() {}

    public struct Update: Sendable {
        public let live: String
        public let liveSpeaker: String?
        public let liveLanguage: String?
        public let liveTranslation: String?
        public let finals: [SonioxSegment]
        public init(live: String, liveSpeaker: String?, liveLanguage: String?,
                    liveTranslation: String?, finals: [SonioxSegment]) {
            self.live = live; self.liveSpeaker = liveSpeaker; self.liveLanguage = liveLanguage
            self.liveTranslation = liveTranslation; self.finals = finals
        }
    }

    public func ingest(_ message: SonioxMessage) -> Update {
        var finals: [SonioxSegment] = []
        var partial = ""
        var translationPartial = ""
        // Index (into THIS ingest's finals) of the segment that just closed, so a
        // translation chunk arriving right after the endpoint marker in the same message
        // attaches to it instead of bleeding into the next line. Local: a segment from a
        // prior ingest was already returned and cannot be amended.
        var lastSegmentIndex: Int?
        for token in message.tokens ?? [] {
            if token.isEndpointMarker {
                if !finalText.isEmpty {
                    finals.append(SonioxSegment(text: finalText, speakerLabel: speaker,
                                                language: language, translation: emptyToNil(translationFinal)))
                    lastSegmentIndex = finals.count - 1
                    finalText = ""; translationFinal = ""
                }
                continue
            }
            if token.translationStatus == "translation" {
                // Translation of the current (or just-closed) utterance, in the target
                // language. Final translation tokens accumulate; partials show live.
                if token.isFinal == true {
                    if finalText.isEmpty, let idx = lastSegmentIndex, idx < finals.count {
                        // The original segment already closed this ingest; attach the late
                        // translation chunk to it rather than bleeding into the next line.
                        let s = finals[idx]
                        finals[idx] = SonioxSegment(text: s.text, speakerLabel: s.speakerLabel,
                                                    language: s.language,
                                                    translation: emptyToNil((s.translation ?? "") + token.text))
                    } else {
                        translationFinal += token.text
                    }
                } else {
                    translationPartial += token.text
                }
                continue
            }
            // Original speech token.
            if token.isFinal == true {
                if let s = token.speaker, s != speaker, !finalText.isEmpty {
                    // Speaker changed mid-stream: close the previous line first.
                    finals.append(SonioxSegment(text: finalText, speakerLabel: speaker,
                                                language: language, translation: emptyToNil(translationFinal)))
                    lastSegmentIndex = finals.count - 1
                    finalText = ""; translationFinal = ""
                }
                if let s = token.speaker { speaker = s }
                if let l = token.language { language = l }
                finalText += token.text
            } else {
                partial += token.text
            }
        }
        let live = finalText + partial
        let liveTranslation = emptyToNil(translationFinal + translationPartial)
        return Update(live: live, liveSpeaker: speaker, liveLanguage: language,
                      liveTranslation: liveTranslation, finals: finals)
    }

    /// Flush any remaining final text as a segment (call on stream end).
    public func flush() -> SonioxSegment? {
        guard !finalText.isEmpty else { return nil }
        let seg = SonioxSegment(text: finalText, speakerLabel: speaker, language: language,
                                translation: emptyToNil(translationFinal))
        finalText = ""; translationFinal = ""
        return seg
    }

    private func emptyToNil(_ s: String) -> String? {
        s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
    }
}
