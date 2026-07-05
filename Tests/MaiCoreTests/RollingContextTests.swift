import Testing
import Foundation
@testable import MaiCore

@Suite struct RollingContextTests {
    @Test func cappedWindowKeepsRecentContextWithinBudget() {
        var context = RollingContext(maxTurns: 10, maxSeconds: 120)
        let now = Date()
        context.append(TranscriptEvent(text: "oldest line that should fall away", speaker: "A", timestamp: now, isFinal: true))
        context.append(TranscriptEvent(text: "middle line that can be omitted", speaker: "B", timestamp: now, isFinal: true))
        context.append(TranscriptEvent(text: "newest line with the useful topic Kubernetes", speaker: "C", timestamp: now, isFinal: true))

        let capped = context.window(maxChars: 90)

        #expect(capped.count <= 90)
        #expect(capped.contains("Kubernetes"))
        #expect(capped.contains("omitted"))
        #expect(!capped.contains("oldest line"))
    }

    @Test func zeroBudgetWindowIsEmpty() {
        var context = RollingContext(maxTurns: 2, maxSeconds: 120)
        context.append(TranscriptEvent(text: "hello", speaker: nil, timestamp: Date(), isFinal: true))

        #expect(context.window(maxChars: 0).isEmpty)
    }
}
