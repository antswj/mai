import Testing
import Foundation
@testable import MaiCore

@Suite struct CardizeTests {
    private func cardizer(floor: Language = .ja, meeting: Bool = true) -> Cardize {
        Cardize(llm: StubLLM(), model: "stub", interfaceLanguage: .en, floorLanguage: floor,
                meetingMode: meeting, furigana: true, pinyin: true)
    }
    private func placeTrigger() -> Trigger {
        Trigger(type: .place, span: "sushi", reason: "r", confidence: 0.85, payload: ["query": "sushi"])
    }

    @Test func preparedLineJapaneseHasReadingsAndTranslation() async throws {
        let c = cardizer(floor: .ja)
        let t = Trigger(type: .reference, span: "respond", reason: "r", confidence: 0.85, payload: ["speaker": "Sato"])
        let card = try #require(await c.make(trigger: t, result: .preparedReply(context: "...", asker: "Sato"), now: Date()))
        #expect(card.tier == .critical)
        #expect(card.body.contains("確認(かくにん)"))
        #expect(card.body.contains("Understood"))
        #expect(card.body.contains("Adjust as needed"))
    }

    @Test func placeCardGoogleHasActionAndRating() async throws {
        let c = cardizer()
        let g = Place(name: "Sushi X", source: "google", rating: 4.6, reviewCount: 100,
                      address: "Addr", lat: 35.70, lng: 139.98, url: "https://maps.google.com/?cid=1", distanceMeters: 120)
        let card = try #require(await c.make(trigger: placeTrigger(), result: .places(query: "sushi", results: [g]), now: Date()))
        #expect(card.action?.kind == "open_in_maps")
        #expect(card.action?.params["url"] == "https://maps.google.com/?cid=1")
        #expect(card.body.contains("★4.6"))
        #expect(card.body.contains("m away"))
        #expect(!card.body.contains("ホットペッパー"), "no Hot Pepper credit for a Google pick")
    }

    @Test func placeCardHotPepperShowsAttribution() async throws {
        let c = cardizer()
        let hp = Place(name: "Sushi Y", source: "hotpepper", rating: nil, reviewCount: nil,
                       address: "Addr", lat: 35.70, lng: 139.98, url: "https://www.hotpepper.jp/strJ000/", distanceMeters: 200)
        let card = try #require(await c.make(trigger: placeTrigger(), result: .places(query: "sushi", results: [hp]), now: Date()))
        #expect(card.body.contains("Powered by ホットペッパーグルメ Webサービス"))
        #expect(card.action?.params["url"] == "https://www.hotpepper.jp/strJ000/")
    }

    @Test func funFactHasNoAction() async throws {
        let c = cardizer()
        let t = Trigger(type: .intent, span: "Malaysia", reason: "r", confidence: 0.7, payload: ["query": "Malaysia"])
        let card = try #require(await c.make(trigger: t, result: .knowledge(topic: "Malaysia", isRecipe: false), now: Date()))
        #expect(card.action == nil)
        #expect(!card.body.isEmpty)
    }

    @Test func summaryProduced() async throws {
        let c = cardizer()
        let s = try #require(await c.summary(window: "Sato: hello\nLee: world"))
        #expect(!s.isEmpty)
    }
}
