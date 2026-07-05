import Testing
import Foundation
@testable import MaiCore

@Suite struct ClassifierTests {
    final class CountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }
    struct CountingLLM: LLMProvider {
        let box: CountBox
        let response: String
        init(box: CountBox, response: String = #"{"triggers":[]}"#) {
            self.box = box
            self.response = response
        }
        func complete(system: String, user: String, model: String) async throws -> String {
            box.bump()
            return response
        }
    }

    private func makeClassifier() -> Classifier {
        Classifier(llm: StubLLM(), model: "stub",
                   enabled: ["place", "question", "intent", "reference", "screenReference"],
                   cooldownSeconds: 90)
    }

    @Test func mixedLanguageSushiFiresPlace() async {
        let c = makeClassifier()
        let triggers = await c.classify(window: "Lee: ngl ちょっとお寿司を食べたい気分", now: Date())
        #expect(triggers.count == 1)
        #expect(triggers.first?.type == .place)
        #expect(triggers.first?.payload["query"] == "sushi")
    }

    @Test func boringLineStaysQuiet() async {
        let c = makeClassifier()
        let triggers = await c.classify(window: "Sato: おはようございます。今日もよろしくお願いします。", now: Date())
        #expect(triggers.isEmpty, "boring small talk must not fire")
    }

    @Test func pureAcknowledgementSkipsLLM() async {
        let box = CountBox()
        let c = Classifier(llm: CountingLLM(box: box), model: "stub",
                           enabled: ["place", "question", "intent", "reference", "screenReference"],
                           cooldownSeconds: 90)
        let triggers = await c.classify(window: "Lee: yeah", now: Date())
        #expect(triggers.isEmpty)
        #expect(box.count == 0, "pure filler should not spend a classifier call")
    }

    @Test func obviousScreenCueSkipsLLM() async {
        let box = CountBox()
        let c = Classifier(llm: CountingLLM(box: box), model: "stub",
                           enabled: ["place", "question", "intent", "reference", "screenReference"],
                           cooldownSeconds: 90)
        let triggers = await c.classify(window: "Sato: 画面を見てください。", now: Date())

        #expect(triggers.first?.type == .screenReference)
        #expect(box.count == 0)
    }

    @Test func exactAnswerCueSkipsLLM() async {
        let box = CountBox()
        let c = Classifier(llm: CountingLLM(box: box), model: "stub",
                           enabled: ["place", "question", "intent", "reference", "screenReference"],
                           cooldownSeconds: 90)
        let triggers = await c.classify(window: "Lee: what's 15% of 80?", now: Date())

        #expect(triggers.first?.type == .question)
        #expect(triggers.first?.payload["query"]?.contains("15%") == true)
        #expect(box.count == 0)
    }

    @Test func screenReferenceJapanese() async {
        let c = makeClassifier()
        let triggers = await c.classify(window: "Sato: 画面を見てください。", now: Date())
        #expect(triggers.first?.type == .screenReference)
    }

    @Test func referenceChinese() async {
        let c = makeClassifier()
        let triggers = await c.classify(window: "Chen: 你怎么看？请说一下你的想法。", now: Date())
        #expect(triggers.first?.type == .reference)
    }

    @Test func cooldownSuppressesRefire() async {
        let c = makeClassifier()
        let now = Date()
        let first = await c.classify(window: "Lee: sushi please", now: now)
        #expect(first.count == 1)
        let second = await c.classify(window: "Lee: sushi please", now: now.addingTimeInterval(5))
        #expect(second.isEmpty, "same trigger within cooldown must not re-emit")
        let later = await c.classify(window: "Lee: sushi please", now: now.addingTimeInterval(120))
        #expect(later.count == 1, "after the cooldown it may fire again")
    }

    @Test func disabledTriggerTypeFiltered() async {
        let c = Classifier(llm: StubLLM(), model: "stub", enabled: ["question"], cooldownSeconds: 90)
        let triggers = await c.classify(window: "Lee: sushi please", now: Date())
        #expect(triggers.isEmpty, "place is not in the enabled set")
    }
}
