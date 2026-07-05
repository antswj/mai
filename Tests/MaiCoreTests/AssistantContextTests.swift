import Testing
@testable import MaiCore

@Suite struct AssistantContextTests {
    @Test func noteRequestUsesOriginalStringIndicesAfterUnicodePrefix() {
        #expect(AssistantContext.noteRequest("İstanbul note this down: call the vendor") == "call the vendor")
        #expect(AssistantContext.noteRequest("NOTE THIS DOWN - confirm venue booking") == "confirm venue booking")
    }
}
