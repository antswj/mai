import Foundation

// The live-transcript translation seam. The toggle shows each line's translation in
// the interface language beneath it.
//
// The one axis that varies between engines:
//  - `inlineOnTranscriptStream == true` (Soniox): the translation already arrives on
//    the transcript stream (the segmenter pairs it per line); `translate` returns nil.
//  - `inlineOnTranscriptStream == false`: a per-line engine that translates each
//    FINALIZED line. The app calls `translate(line:from:)` when a line finalizes and
//    shows the result. Such a provider translates finalized lines only, so live partials
//    stay in the original language until they finalize, which is the inherent difference
//    from the inline path.
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

// Per-line translation by a hosted model, selected with
// `[stt] translation_engine = "model"`. The inline path depends on the speech service
// producing translations itself; this one works with ANY speech provider, and in the
// simulated dev mode, at the cost of one small call per finalized line.
//
// Finalized lines only, so live partials stay in the original language until they
// settle. Results are cached per line, so a repeated line costs nothing.
public final class ModelTranslation: TranslationProvider, @unchecked Sendable {
    public let target: Language
    public var inlineOnTranscriptStream: Bool { false }
    private let llm: LLMProvider
    private let model: String
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private static let cacheLimit = 500

    public init(target: Language, llm: LLMProvider, model: String) {
        self.target = target; self.llm = llm; self.model = model
    }

    public func translate(line: String, from: Language?) async -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return nil }
        // Already in the target language: there is nothing useful to show underneath.
        if (from ?? ScriptDetect.language(of: text)) == target { return nil }
        let key = "\(target.rawValue)|\(text)"
        if let hit = lock.withLock({ cache[key] }) { return hit }

        let user = "Target language: \(LookupRouter.name(target))\nLine:\n\(text)"
        guard let raw = try? await llm.complete(system: Prompts.translate, user: user, model: model) else {
            return nil
        }
        let out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out.caseInsensitiveCompare(text) != .orderedSame else { return nil }
        lock.withLock {
            if cache.count >= Self.cacheLimit { cache.removeAll() }   // simple bound, not an LRU
            cache[key] = out
        }
        return out
    }
}

public enum TranslationFactory {
    // Selected by config.translationEngine (default "soniox"). "model" translates each
    // finalized line with the drafter model, which works with any speech provider. It
    // falls back to the inline provider when no model is available, so a misconfigured
    // engine degrades instead of silently dropping translations.
    public static func make(engine: String, target: Language,
                            llm: LLMProvider? = nil, model: String = "") -> TranslationProvider {
        switch engine {
        case "model":
            guard let llm else { return SonioxTranslation(target: target) }
            return ModelTranslation(target: target, llm: llm, model: model)
        default:
            return SonioxTranslation(target: target)
        }
    }
}
