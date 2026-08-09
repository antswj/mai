import Testing
import Foundation
@testable import MaiCore

@Suite struct CaptureHealthTests {
    /// Both sources delivering, nobody speaking. An always-on assistant sits like this
    /// for hours, so it must never be treated as a fault.
    @Test func quietRoomIsHealthy() {
        let quiet = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                       micVoicedAgo: 300, sentAgo: 300, transcriptAgo: 300)
        #expect(CaptureHealthPolicy.verdict(quiet) == .healthy)
    }

    @Test func deadCaptureStackRestarts() {
        let dead = CaptureHealthInput(micCapturedAgo: 30, systemCapturedAgo: 30,
                                      micVoicedAgo: 60, sentAgo: 60, transcriptAgo: 60)
        if case .restart = CaptureHealthPolicy.verdict(dead) {} else {
            Issue.record("expected a restart when no source delivers audio")
        }
    }

    @Test func stalledTranscriptionRestarts() {
        let stalled = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                         micVoicedAgo: 2, sentAgo: 2, transcriptAgo: 40)
        if case .restart = CaptureHealthPolicy.verdict(stalled) {} else {
            Issue.record("expected a restart when audio flows but no transcript returns")
        }
    }

    /// The regression this policy exists for. The microphone leg stopped while system
    /// audio kept arriving, so the old shared heartbeat stayed fresh and "sent" grew
    /// without bound: neither old rule could fire, and the app reported "Capturing"
    /// while transcribing nothing.
    @Test func deadMicLegIsDetectedAndWasPreviouslyInvisible() {
        let micDead = CaptureHealthInput(micCapturedAgo: 200, systemCapturedAgo: 0.2,
                                         micVoicedAgo: 4_000, sentAgo: 4_000, transcriptAgo: 4_000)
        #expect(micDead.capturedAgo < CaptureHealthPolicy.deadCaptureSeconds)
        #expect(!(micDead.sentAgo < 6 && micDead.transcriptAgo > 20))
        if case .restart(let why) = CaptureHealthPolicy.verdict(micDead) {
            #expect(why.hasPrefix("microphone stopped"))
        } else {
            Issue.record("expected a restart for a dead microphone leg")
        }
    }

    @Test func spentRecoveryBudgetReportsInsteadOfLooping() {
        var exhausted = CaptureHealthInput(micCapturedAgo: 200, systemCapturedAgo: 0.2,
                                           micVoicedAgo: 4_000, sentAgo: 4_000, transcriptAgo: 4_000)
        exhausted.micRecoveryAttempts = CaptureHealthPolicy.maxMicRecoveryAttempts
        if case .warn(let message) = CaptureHealthPolicy.verdict(exhausted) {
            #expect(message.contains("Microphone"))
        } else {
            Issue.record("expected a warning once the restart budget is spent")
        }
    }

    @Test func mutedMicrophoneIsNeverAFault() {
        var muted = CaptureHealthInput(micCapturedAgo: 200, systemCapturedAgo: 0.2,
                                       micVoicedAgo: 4_000, sentAgo: 4_000, transcriptAgo: 4_000)
        muted.micMuted = true
        #expect(CaptureHealthPolicy.verdict(muted) == .healthy)
    }

    /// Transcription errors used to be discarded entirely, so a rejected key looked
    /// exactly like a quiet room.
    @Test func freshErrorsSurfaceAndStaleOnesDoNot() {
        let failing = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                         micVoicedAgo: 500, sentAgo: 500, transcriptAgo: 500,
                                         errorAgo: 5, lastError: "soniox error 402: balance exhausted")
        if case .warn(let message) = CaptureHealthPolicy.verdict(failing) {
            #expect(message.contains("402"))
        } else {
            Issue.record("expected a fresh transcription error to surface")
        }

        var stale = failing
        stale.errorAgo = CaptureHealthPolicy.errorFreshSeconds + 60
        stale.sentAgo = 60
        stale.micVoicedAgo = 600
        #expect(CaptureHealthPolicy.verdict(stale) == .healthy)
    }

    @Test func speechHeardButNeverForwardedWarns() {
        let heardNotSent = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                              micVoicedAgo: 5, sentAgo: 400, transcriptAgo: 400)
        if case .warn(let message) = CaptureHealthPolicy.verdict(heardNotSent) {
            #expect(message.contains("heard"))
        } else {
            Issue.record("expected a warning when audio is heard but never forwarded")
        }
    }

    /// A long quiet stretch is informational, never a status-line warning, and its text
    /// must not embed an elapsed time: the app republishes only on a text change, so an
    /// interpolated duration would rewrite the UI every minute forever.
    @Test func longSilenceIsAStableNotice() {
        let longSilence = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                             micVoicedAgo: 5_000,
                                             sentAgo: CaptureHealthPolicy.silentTooLongSeconds + 60,
                                             transcriptAgo: 5_000)
        guard case .notice(let message) = CaptureHealthPolicy.verdict(longSilence) else {
            Issue.record("expected a notice for a long quiet stretch")
            return
        }
        #expect(message.contains("No speech"))

        var later = longSilence
        later.sentAgo += 600
        #expect(CaptureHealthPolicy.verdict(later) == .notice(message))

        var muted = longSilence
        muted.micMuted = true
        #expect(CaptureHealthPolicy.verdict(muted) == .healthy)
    }

    @Test func detailReadsAsAgesNotRawNumbers() {
        let micDead = CaptureHealthInput(micCapturedAgo: 200, systemCapturedAgo: 0.2,
                                         micVoicedAgo: 4_000, sentAgo: 4_000, transcriptAgo: 4_000)
        let detail = CaptureHealthPolicy.detail(micDead)
        #expect(detail.contains("Microphone audio"))
        #expect(CaptureHealthPolicy.age(.greatestFiniteMagnitude) == "never")
        #expect(CaptureHealthPolicy.age(30) == "30s ago")
        #expect(CaptureHealthPolicy.age(600) == "10m ago")
    }
}
