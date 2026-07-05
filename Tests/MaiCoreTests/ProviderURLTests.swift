import Testing
import Foundation
@testable import MaiCore

@Suite struct ProviderURLTests {
    @Test func wikipediaLanglinkURLPreservesReservedTitleCharacters() throws {
        let title = "AT&T + R&D = fun/why?"
        let url = try #require(WikipediaLookup.langlinkURL(lang: "en", title: title, to: "ja"))
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let titles = comps.queryItems?.first { $0.name == "titles" }?.value

        #expect(comps.host == "en.wikipedia.org")
        #expect(titles == title)
    }
}
