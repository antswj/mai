import Foundation

// Shared models for the always-on live transcript and the capture indicator. Live
// in MaiCore so both the capture layer and the SwiftUI app use one definition.

public enum CaptureState: Sendable, Equatable {
    case starting
    case capturing
    case paused
    case unavailable(String)   // reason, e.g. a missing permission
    case simulated             // dev path: typed lines and injected screens
}

// One line of the live transcript. The view computes ruby locally from `text` and
// `language`; `translation` is the optional dimmer line shown underneath.
public struct LiveTranscriptLine: Sendable, Identifiable {
    public let id: String
    public var speaker: String
    public var source: SpeakerSource
    public var cluster: String?   // diarization label, for a manual rename
    public var text: String
    public var language: Language?
    public var translation: String?
    public var isFinal: Bool
    public init(id: String, speaker: String, source: SpeakerSource, cluster: String? = nil, text: String,
                language: Language?, translation: String? = nil, isFinal: Bool) {
        self.id = id; self.speaker = speaker; self.source = source; self.cluster = cluster; self.text = text
        self.language = language; self.translation = translation; self.isFinal = isFinal
    }
}
