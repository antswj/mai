import Testing
import Foundation
@testable import MaiCore

@Suite struct ConversationCoachTests {
    private func vocal(_ source: SpeakerSource) -> VocalSignal {
        VocalSignal(source: source, capturedAt: Date(), windowSeconds: 12,
                    capturedSeconds: 4, speechSeconds: 2.3, silenceRatio: 0.42,
                    meanRMS: 0.08, peakRMS: 0.31, energyTrend: -0.04,
                    meanPitchHz: 172, pitchStdDevHz: 26, pitchSampleCount: 8,
                    wordCount: 12, estimatedWordsPerMinute: 205)
    }

    private func event(_ text: String, language: String?, source: SpeakerSource) -> TranscriptEvent {
        TranscriptEvent(text: text, speaker: "Sato", timestamp: Date(), isFinal: true,
                        language: language, vocalSignal: vocal(source), source: source)
    }

    @Test func promptFileLoadsAndKeepsItsContract() {
        let prompt = Prompts.coach
        #expect(!prompt.isEmpty)
        // The deterministic stub dispatches on this phrase.
        #expect(prompt.contains("live vocal coaching analyst"))
        #expect(prompt.contains("suggested_reply"))
        #expect(prompt.contains("reply_translation"))
        #expect(!prompt.contains("\u{2014}"))
    }

    @Test func replyFollowsTheOtherPartysLanguage() async throws {
        let ja = try await ConversationCoach.aiInsight(
            for: event("その価格だと、社内の承認が難しいかもしれません。", language: "ja", source: .remote),
            window: "Sato (other, ja): その価格だと、社内の承認が難しいかもしれません。",
            llm: StubLLM(), model: "stub", interfaceLanguage: .en,
            spokenLanguage: .ja, suggestReplies: true)
        #expect(ja?.response?.language == .ja)
        #expect(ja?.response?.spoken.isEmpty == false)
        #expect(ja?.response?.translation.isEmpty == false)
        // The reading aid is generated locally, so furigana must actually come out.
        let units = Readings.units(ja?.response?.spoken ?? "", language: .ja)
        #expect(units.contains { $0.reading != nil })

        let zh = try await ConversationCoach.aiInsight(
            for: event("这个价格我们内部很难批下来。", language: "zh", source: .remote),
            window: "Sato (other, zh): 这个价格我们内部很难批下来。",
            llm: StubLLM(), model: "stub", interfaceLanguage: .en,
            spokenLanguage: .zh, suggestReplies: true)
        #expect(zh?.response?.language == .zh)
        #expect(Readings.units(zh?.response?.spoken ?? "", language: .zh).contains { $0.reading != nil })
    }

    @Test func onlyTheOtherPartyGetsAReply() async throws {
        let mine = try await ConversationCoach.aiInsight(
            for: event("その価格だと、社内の承認が難しいかもしれません。", language: "ja", source: .user),
            window: "You (you, ja): その価格だと、社内の承認が難しいかもしれません。",
            llm: StubLLM(), model: "stub", interfaceLanguage: .en,
            spokenLanguage: .ja, suggestReplies: true)
        #expect(mine != nil)
        #expect(mine?.response == nil)

        let gated = try await ConversationCoach.aiInsight(
            for: event("その価格だと、社内の承認が難しいかもしれません。", language: "ja", source: .remote),
            window: "Sato (other, ja): ...",
            llm: StubLLM(), model: "stub", interfaceLanguage: .en,
            spokenLanguage: .ja, suggestReplies: false)
        #expect(gated?.response == nil)
    }

    @Test func speakerSourceFallsBackToTheVocalSignal() {
        let legacy = TranscriptEvent(text: "hello there", speaker: "Sato", timestamp: Date(),
                                     isFinal: true, language: "en", vocalSignal: vocal(.remote))
        #expect(ConversationCoach.speakerSource(of: legacy) == .remote)
        let none = TranscriptEvent(text: "hello there", speaker: "Sato", timestamp: Date(), isFinal: true)
        #expect(ConversationCoach.speakerSource(of: none) == nil)
    }

    /// The reply is what the user says out loud, so the safety filter has to cover it and
    /// a hit rejects the whole output, not just the reply.
    @Test func safetyFilterCoversTheReply() async throws {
        let unsafe = StubLLM { _, _, _ in
            #"{"should_surface":true,"headline":"Push back","info":"This is a reasonable moment to ask for specifics about the constraint.","recommended_move":"Ask for specifics.","suggested_reply":"Tell them you know they are lying about the budget.","reply_translation":"Tell them you know they are lying.","tier":"medium","score":0.8,"observed_voice_cues":["tone"]}"#
        }
        let blocked = try await ConversationCoach.aiInsight(
            for: event("That price is hard to approve.", language: "en", source: .remote),
            window: "Sato (other, en): That price is hard to approve.",
            llm: unsafe, model: "stub", interfaceLanguage: .en,
            spokenLanguage: .en, suggestReplies: true)
        #expect(blocked == nil)
    }

    @Test func englishReplyToAJapaneseSpeakerIsDropped() async throws {
        let mismatched = StubLLM { _, _, _ in
            #"{"should_surface":true,"headline":"Ask for specifics","info":"This is a good moment to ask what would make the approval easier internally.","recommended_move":"Ask one clarifying question.","suggested_reply":"Could you tell me more about that?","reply_translation":"Could you tell me more about that?","tier":"medium","score":0.8,"observed_voice_cues":["pace"]}"#
        }
        let parity = try await ConversationCoach.aiInsight(
            for: event("その価格だと、社内の承認が難しいかもしれません。", language: "ja", source: .remote),
            window: "Sato (other, ja): ...",
            llm: mismatched, model: "stub", interfaceLanguage: .en,
            spokenLanguage: .ja, suggestReplies: true)
        #expect(parity != nil)          // the analysis survives
        #expect(parity?.response == nil) // the wrong-language reply does not
    }

    @Test func heuristicPathIsLocalizedAndNeverReplies() {
        let e = TranscriptEvent(text: "I'm worried the timeline risk is still too high.",
                                speaker: "Mia", timestamp: Date(), isFinal: true)
        let w = "Mia: I'm worried the timeline risk is still too high."
        let en = ConversationCoach.insight(for: e, window: w, interfaceLanguage: .en)
        let ja = ConversationCoach.insight(for: e, window: w, interfaceLanguage: .ja)
        let zh = ConversationCoach.insight(for: e, window: w, interfaceLanguage: .zh)
        #expect(en?.headline == "Address the concern")   // unchanged
        #expect(ja?.headline != en?.headline)
        #expect(zh?.headline != en?.headline)
        // The cooldown key must not move when the interface language changes.
        #expect(en?.key == ja?.key)
        #expect(ja?.key == zh?.key)
        #expect(en?.response == nil)
        #expect(ja?.response == nil)
        #expect(zh?.response == nil)
    }

    /// ScriptDetect maps Han-without-kana to zh, so trusting the script first would put
    /// pinyin over all-kanji Japanese. The tag has to win.
    @Test func rubyLanguagePrefersTheTagThenTheScript() {
        #expect(RichResponse(spoken: "承認は来週です。", translation: "t", language: .ja, rationale: nil).rubyLanguage == .ja)
        #expect(RichResponse(spoken: "もう少し詳しく教えてください。", translation: "t", language: .en, rationale: nil).rubyLanguage == .ja)
        #expect(RichResponse(spoken: "请再说一点。", translation: "t", language: .zh, rationale: nil).rubyLanguage == .zh)
        #expect(RichResponse(spoken: "Could you say more?", translation: "t", language: .en, rationale: nil).rubyLanguage == .en)
    }

    /// A replayed trace has to reproduce coach behavior, so the speaker source must
    /// survive the anonymize and decode round trip.
    @Test func traceRoundTripsTheSpeakerSource() throws {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let e = event("その価格だと、社内の承認が難しいかもしれません。", language: "ja", source: .remote)
        let traced = try #require(TraceAnonymizer.transcript(e, sessionStartedAt: start))
        #expect(traced.source == SpeakerSource.remote.rawValue)

        let trace = MaiTrace(startedAt: start, events: [traced])
        guard case .transcript(let back) = trace.input(for: traced) else {
            Issue.record("expected a transcript input")
            return
        }
        #expect(back.source == .remote)
    }
}
