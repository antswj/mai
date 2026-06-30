import Foundation

// The live-transcript translation seam. The toggle shows each line's translation in
// the interface language beneath it. The current implementation is Soniox real-time
// translation on the SAME stream (the translation rides the transcript WebSocket, so
// it is as instant as the transcript, with no extra round trip). The seam exists so a
// different engine can replace it later via a config change, with no UI change.
//
// The one axis that varies between engines:
//  - `inlineOnTranscriptStream == true` (Soniox): the translation already arrives on
//    the transcript stream (the segmenter pairs it per line); `translate` returns nil.
//  - `inlineOnTranscriptStream == false`: a per-line engine (for example a model that
//    translates each FINALIZED line). The app calls `translate(line:from:)` when a
//    line finalizes and shows the result. Such a provider translates finalized lines
//    only, so live partials stay in the original language until they finalize, which
//    is the inherent difference from the inline Soniox path.
//
// A model-based provider (for example Claude Sonnet, if Soniox quality is judged
// insufficient) implements this same protocol with `inlineOnTranscriptStream = false`
// and a real `translate(line:from:)`, selected via config. It is NOT built here.
public protocol TranslationProvider: Sendable {
    var target: Language { get }
    var inlineOnTranscriptStream: Bool { get }
    func translate(line: String, from: Language?) async -> String?
}

// Soniox same-stream translation: the translation is produced inline by the speech
// model on the same WebSocket, so there is nothing to call per line.
public struct SonioxTranslation: TranslationProvider {
    public let target: Language
    public var inlineOnTranscriptStream: Bool { true }
    public init(target: Language) { self.target = target }
    public func translate(line: String, from: Language?) async -> String? { nil }
}

public enum TranslationFactory {
    // Selected by config.translationEngine (default "soniox"). A future "model" engine
    // would return a model-based provider here; the rest of the app is unchanged.
    public static func make(engine: String, target: Language) -> TranslationProvider {
        switch engine {
        // case "model": return ModelTranslation(target: target)   // future, not built
        default: return SonioxTranslation(target: target)
        }
    }
}
