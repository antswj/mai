import Foundation

public enum SessionAutomationDecision: Sendable, Equatable {
    case none
    case rotate(reason: String)
}

public enum SessionAutomation {
    public static func decision(
        enabled: Bool,
        sessionActive: Bool,
        hasContent: Bool,
        now: Date,
        startedAt: Date?,
        lastActivityAt: Date,
        idleRolloverSeconds: Double,
        maxSessionSeconds: Double
    ) -> SessionAutomationDecision {
        guard enabled, sessionActive, hasContent else { return .none }

        let idle = now.timeIntervalSince(lastActivityAt)
        if idleRolloverSeconds > 0, idle >= idleRolloverSeconds {
            return .rotate(reason: "idle for \(Self.minutes(idle)) min")
        }

        if let startedAt, maxSessionSeconds > 0 {
            let age = now.timeIntervalSince(startedAt)
            if age >= maxSessionSeconds {
                return .rotate(reason: "session reached \(Self.hours(age)) hr")
            }
        }

        return .none
    }

    private static func minutes(_ seconds: Double) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }

    private static func hours(_ seconds: Double) -> Int {
        max(1, Int((seconds / 3600).rounded()))
    }
}
