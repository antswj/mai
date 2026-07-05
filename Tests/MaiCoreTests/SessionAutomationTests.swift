import Testing
import Foundation
@testable import MaiCore

@Suite struct SessionAutomationTests {
    @Test func idleContentRotates() {
        let now = Date(timeIntervalSince1970: 10_000)
        let decision = SessionAutomation.decision(
            enabled: true,
            sessionActive: true,
            hasContent: true,
            now: now,
            startedAt: now.addingTimeInterval(-600),
            lastActivityAt: now.addingTimeInterval(-1_500),
            idleRolloverSeconds: 1_200,
            maxSessionSeconds: 14_400)

        if case .rotate(let reason) = decision {
            #expect(reason.contains("idle"))
        } else {
            Issue.record("expected idle rollover")
        }
    }

    @Test func emptyOrDisabledSessionsDoNotRotate() {
        let now = Date()
        #expect(SessionAutomation.decision(enabled: true, sessionActive: true, hasContent: false,
                                           now: now, startedAt: now.addingTimeInterval(-99_999),
                                           lastActivityAt: now.addingTimeInterval(-99_999),
                                           idleRolloverSeconds: 60, maxSessionSeconds: 60) == .none)
        #expect(SessionAutomation.decision(enabled: false, sessionActive: true, hasContent: true,
                                           now: now, startedAt: now.addingTimeInterval(-99_999),
                                           lastActivityAt: now.addingTimeInterval(-99_999),
                                           idleRolloverSeconds: 60, maxSessionSeconds: 60) == .none)
    }

    @Test func maxLengthRotatesEvenWhenRecentlyActive() {
        let now = Date(timeIntervalSince1970: 10_000)
        let decision = SessionAutomation.decision(
            enabled: true,
            sessionActive: true,
            hasContent: true,
            now: now,
            startedAt: now.addingTimeInterval(-15_000),
            lastActivityAt: now.addingTimeInterval(-30),
            idleRolloverSeconds: 1_200,
            maxSessionSeconds: 14_400)

        if case .rotate(let reason) = decision {
            #expect(reason.contains("session reached"))
        } else {
            Issue.record("expected max-length rollover")
        }
    }
}
