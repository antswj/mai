import Testing
import Foundation
@testable import MaiCore

@Suite struct CardRatingTests {
    @Test func sourcedActionableCardsRateHighly() {
        let card = RichCard(trigger: .place, timestamp: Date(), route: .place,
                            score: 0.86, headline: "Nearby: sushi",
                            info: "Sushi HP\n~150 m away\nFunabashi",
                            source: RichSource(title: "Maps", url: "https://example.com"),
                            action: Action(kind: "open_in_maps", label: "Open in Maps", params: ["url": "https://maps.example"]))

        let rating = CardRating.evaluate(card)

        #expect(rating.useful)
        #expect(rating.score >= 0.85)
        #expect(rating.reasons.contains("actionable"))
    }

    @Test func connectivityFallbackRatesWeak() {
        let card = RichCard(trigger: .question, timestamp: Date(), route: .technical,
                            score: 0.60, headline: "Anything",
                            info: RichCardEnricher.noResult(.en))

        let rating = CardRating.evaluate(card)

        #expect(!rating.useful)
        #expect(rating.grade == "weak")
        #expect(rating.reasons.contains("fallback only"))
    }

    @Test func unsourcedButSpecificModelAnswerCanStillBeUseful() {
        let card = RichCard(trigger: .question, timestamp: Date(), route: .technical,
                            score: 0.62, headline: "Private project",
                            info: "A good next step is to split the upload queue from the rendering worker so retries do not block UI updates.",
                            unverified: true)

        let rating = CardRating.evaluate(card)

        #expect(rating.useful)
        #expect(rating.reasons.contains("unverified"))
    }
}
