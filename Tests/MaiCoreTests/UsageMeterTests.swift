import Foundation
import Testing
@testable import MaiCore

@Suite struct UsageMeterTests {
    @Test func firstRecordAfterMidnightIsKeptOnNewDay() async {
        final class ClockBox: @unchecked Sendable {
            var day = "2026-07-05"
        }

        let clock = ClockBox()
        let meter = UsageMeter(dayKey: { clock.day })

        await meter.recordModel()
        let before = await meter.snapshot()
        #expect(before.date == "2026-07-05")
        #expect(before.modelCalls == 1)

        clock.day = "2026-07-06"
        await meter.recordModel()
        let after = await meter.snapshot()
        #expect(after.date == "2026-07-06")
        #expect(after.modelCalls == 1)
    }

    @Test func cachedGroundedSearchCountsOnlyProviderMisses() async throws {
        let meter = UsageMeter()
        let cached = CachedGroundedSearch(
            base: MeteredGrounded(StubGroundedSearch(), meter: meter),
            cacheURL: maiTempDir().appendingPathComponent("grounded.json")
        )

        _ = try await cached.answer(query: "Salesforce Platform Events", interface: .en)
        _ = try await cached.answer(query: " salesforce   platform events ", interface: .en)

        let counts = await meter.snapshot()
        #expect(counts.searchCalls == 1)
    }
}
