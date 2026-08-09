import Foundation

// Liveness policy for the always-on capture pipeline.
//
// The pipeline has three stages that can fail independently: audio arrives from the
// system (per source: microphone and system audio), voiced audio is forwarded to the
// speech service, and the speech service answers with a transcript. The earlier
// watchdog only knew two of those and shared a single "captured" heartbeat across both
// sources, which left a real gap: when the microphone leg stopped delivering while
// system audio kept arriving, "captured" stayed fresh and "sent" grew without bound, so
// neither rule fired and the app reported "Capturing" indefinitely while transcribing
// nothing. These rules close that gap and, where a restart cannot help, say so plainly
// instead of restarting in a loop.
//
// Pure logic with no clock and no I/O so the decisions are unit tested.

/// Seconds since each pipeline event, plus the state needed to judge them.
public struct CaptureHealthInput: Sendable, Equatable {
    /// Since the microphone output last delivered a buffer (silent buffers count).
    public var micCapturedAgo: TimeInterval
    /// Since the system-audio output last delivered a buffer (silent buffers count).
    public var systemCapturedAgo: TimeInterval
    /// Since the microphone last carried audio above the speech-energy threshold.
    public var micVoicedAgo: TimeInterval
    /// Since any audio bytes were forwarded to the speech service.
    public var sentAgo: TimeInterval
    /// Since the speech service last answered.
    public var transcriptAgo: TimeInterval
    /// Since the last capture or speech-service error, and its text.
    public var errorAgo: TimeInterval
    public var lastError: String?
    /// The user muted the microphone on purpose, so a silent mic leg is expected.
    public var micMuted: Bool
    /// How many times the mic leg has already been restarted for this fault.
    public var micRecoveryAttempts: Int

    public init(micCapturedAgo: TimeInterval,
                systemCapturedAgo: TimeInterval,
                micVoicedAgo: TimeInterval,
                sentAgo: TimeInterval,
                transcriptAgo: TimeInterval,
                errorAgo: TimeInterval = .greatestFiniteMagnitude,
                lastError: String? = nil,
                micMuted: Bool = false,
                micRecoveryAttempts: Int = 0) {
        self.micCapturedAgo = micCapturedAgo
        self.systemCapturedAgo = systemCapturedAgo
        self.micVoicedAgo = micVoicedAgo
        self.sentAgo = sentAgo
        self.transcriptAgo = transcriptAgo
        self.errorAgo = errorAgo
        self.lastError = lastError
        self.micMuted = micMuted
        self.micRecoveryAttempts = micRecoveryAttempts
    }

    /// The whole capture stack is dead only when NEITHER source is delivering.
    public var capturedAgo: TimeInterval { min(micCapturedAgo, systemCapturedAgo) }
}

public enum CaptureHealthVerdict: Sendable, Equatable {
    /// Nothing to do.
    case healthy
    /// Rebuild capture: a restart can plausibly fix this.
    case restart(String)
    /// A real fault a restart cannot fix (or would flap on). Worth the status line.
    case warn(String)
    /// Informational only, shown in the Health tab and never in the status line. A long
    /// quiet stretch is the normal state of an always-on assistant, so it must not
    /// displace "Capturing" or read as an error.
    case notice(String)
}

public enum CaptureHealthPolicy {
    /// No audio at all from either source: the capture stack died.
    public static let deadCaptureSeconds: TimeInterval = 12
    /// One source stopped delivering while the other is healthy.
    public static let legDeadSeconds: TimeInterval = 90
    /// The mic heard speech this recently...
    public static let voicedRecentSeconds: TimeInterval = 45
    /// ...but nothing has been forwarded for this long: forwarding is broken.
    public static let voicedNotForwardedSeconds: TimeInterval = 180
    /// Nothing forwarded at all for this long: worth saying, even though silence is normal.
    public static let silentTooLongSeconds: TimeInterval = 1_200
    /// An error this recent is still worth showing.
    public static let errorFreshSeconds: TimeInterval = 90
    /// Restart the mic leg at most this many times before reporting instead of looping.
    public static let maxMicRecoveryAttempts = 2

    public static func verdict(_ i: CaptureHealthInput) -> CaptureHealthVerdict {
        // 1. Nothing from any source: the capture stack is dead, a restart is the fix.
        if i.capturedAgo > deadCaptureSeconds {
            return .restart("capture stalled (no audio for \(Int(i.capturedAgo))s)")
        }
        // 2. Audio is being forwarded but the speech service has gone quiet.
        if i.sentAgo < 6 && i.transcriptAgo > 20 {
            return .restart("transcription stalled (audio flowing, no transcript for \(Int(i.transcriptAgo))s)")
        }
        // 3. The mic leg specifically stopped while system audio keeps arriving. This is
        // the case that used to be invisible. Try a rebuild a couple of times, then stop
        // restarting and say what the user needs to check, because a permission or device
        // problem is not fixed by another restart.
        if !i.micMuted, i.micCapturedAgo > legDeadSeconds, i.systemCapturedAgo <= deadCaptureSeconds {
            if i.micRecoveryAttempts < maxMicRecoveryAttempts {
                return .restart("microphone stopped delivering audio (\(Int(i.micCapturedAgo))s)")
            }
            return .warn("The microphone is not delivering audio. Check System Settings, Privacy and Security, Microphone that Mai is allowed, and that no other app has taken the microphone. System audio and the screen are still being captured.")
        }
        // 4. A capture or speech-service error was reported. These used to be discarded.
        if let text = i.lastError, i.errorAgo < errorFreshSeconds {
            return .warn("Transcription problem: \(text)")
        }
        // 5. The mic is hearing speech but nothing is reaching the speech service, so the
        // fault is between the microphone and the network (voice detection or forwarding).
        if i.micVoicedAgo < voicedRecentSeconds, i.sentAgo > voicedNotForwardedSeconds {
            return .warn("Audio is being heard but nothing is reaching transcription. Voice detection or the transcription connection may be failing.")
        }
        // 6. Nothing forwarded for a long stretch. Silence is normal for an always-on
        // assistant, so this is phrased as a check, not an error. It is the only signal
        // that catches a microphone delivering digital silence (buffers arrive, so rule 3
        // stays quiet, but they contain nothing).
        // The text is deliberately fixed, with no elapsed-time number in it. The app only
        // republishes a health message when the text CHANGES, so an interpolated duration
        // would rewrite the status line every minute forever during ordinary quiet.
        if !i.micMuted, i.sentAgo > silentTooLongSeconds {
            return .notice("No speech has reached transcription for a while. That is normal in a quiet room. If you have been speaking, check the input device in System Settings, Sound, and that Mai has Microphone access.")
        }
        return .healthy
    }

    /// Raw liveness ages, for the Health tab. This is what makes the rules above
    /// observable rather than assumed: it shows whether the microphone is delivering,
    /// whether anything was heard, and whether anything was forwarded.
    public static func detail(_ i: CaptureHealthInput) -> String {
        "Microphone audio \(age(i.micCapturedAgo)), system audio \(age(i.systemCapturedAgo)), speech heard \(age(i.micVoicedAgo)), forwarded to transcription \(age(i.sentAgo))."
    }

    static func age(_ seconds: TimeInterval) -> String {
        if seconds > 86_400 { return "never" }
        if seconds < 90 { return "\(Int(seconds))s ago" }
        return "\(Int(seconds / 60))m ago"
    }
}
