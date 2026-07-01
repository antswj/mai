import Foundation
import MaiCore

// Real ears: ScreenCaptureKit mic + system audio, each converted to PCM16 and
// streamed to its own Soniox connection, merged into one speaker-attributed
// transcript. Implements the MaiCore `Ears` contract: final utterances flow to the
// engine via stream(); live partials flow to the UI via onLive. The audio capture
// and Soniox wiring are added in the capture chunk; this file owns the assembly,
// the speaker registry, and pause (which closes the sockets, not just mutes).
public final class RealEars: Ears, @unchecked Sendable {
    let config: Config
    let secrets: Secrets
    private let _stream: AsyncStream<TranscriptEvent>
    private let cont: AsyncStream<TranscriptEvent>.Continuation

    // UI side-channel (set by the app; hops to the main actor inside the closure).
    public var onLive: (@Sendable (LiveTranscriptLine) -> Void)?
    // Asks the app to clear the in-flight partial for a source (used when a mic echo
    // final is dropped, so the already-shown "You" partial does not linger).
    public var onClearPartial: (@Sendable (SpeakerSource) -> Void)?
    // The app wires this to the eyes' current active-speaker name, for naming.
    public var highlightProvider: (@Sendable () -> String?)?
    // Maps diarization clusters to real names; guarded because mic and system
    // Soniox callbacks can touch it concurrently.
    private var registry = SpeakerRegistry()
    private let registryLock = NSLock()
    // Transcript-level echo suppression: drops a mic ("You") utterance that is a
    // near-identical echo of a recent system-audio utterance (speaker voice picked up
    // by the mic). Guarded; mic and system Soniox callbacks touch it concurrently.
    private var echo = EchoSuppressor()
    private let echoLock = NSLock()
    // Acoustic-echo detection from capture-time energy (robust to how the echo happens
    // to be transcribed). lastSystemLoudAt: the last moment the SPEAKER was actually
    // producing sound (system-audio RMS above threshold). lastConcurrentAt: the last
    // moment the MIC and the SPEAKER were BOTH loud at once (the physical echo
    // condition). A mic utterance that overlapped speaker output is dropped as echo;
    // genuine user speech in a quiet room never overlaps, so it is kept.
    private var lastSystemLoudAt = Date.distantPast
    private var lastConcurrentAt = Date.distantPast
    // How close in time mic-loud and speaker-loud must be to count as concurrent (both
    // are measured at capture, in real time). And how recent that concurrency must be,
    // relative to a mic final (which lags the speech by the endpoint delay), to treat
    // the utterance as echo.
    private let concurrencyWindow: TimeInterval = 0.6
    private let overlapRecency: TimeInterval = 2.5

    // Filled in the capture chunk.
    private var micClient: SonioxClient?
    private var systemClient: SonioxClient?
    private var audioCapture: AudioCapture?
    // VAD gating (Part D): present when enabled and the model loads. Each gate owns
    // its source's Soniox stream lifecycle; audio is routed through it.
    private var micGate: VadGatedSource?
    private var systemGate: VadGatedSource?
    // Spend meter (optional): counts transcription by audio-seconds actually sent, so
    // VAD gating's savings during silence are reflected.
    public var usage: UsageMeter?
    private func recordTranscription(bytes: Int) {
        guard let usage else { return }
        let seconds = Double(bytes) / Double(config.sttSampleRate * 2)   // Int16 mono
        Task { await usage.recordTranscription(seconds: seconds) }
    }

    public init(config: Config, secrets: Secrets) {
        self.config = config
        self.secrets = secrets
        let made = AsyncStream<TranscriptEvent>.makeStream()
        self._stream = made.stream
        self.cont = made.continuation
    }

    public func stream() -> AsyncStream<TranscriptEvent> { _stream }

    public func start() async throws {
        try await startCapture()
    }

    // Liveness heartbeats for the watchdog: when audio was last captured from the
    // system, last forwarded to Soniox, and last heard back from Soniox. These let
    // the app tell "quiet" (normal) apart from "stuck" (audio flowing but no
    // transcript) and "dead" (no audio at all) without false restarts during silence.
    private let healthLock = NSLock()
    private var _capturedAt = Date()
    private var _sentAt = Date.distantPast
    private var _transcriptAt = Date.distantPast
    func noteCaptured() { healthLock.withLock { _capturedAt = Date() } }
    func noteSent() { healthLock.withLock { _sentAt = Date() } }
    func noteTranscript() { healthLock.withLock { _transcriptAt = Date() } }
    public func resetHealth() { healthLock.withLock { let now = Date(); _capturedAt = now; _sentAt = now; _transcriptAt = now } }
    public func health() -> (capturedAgo: TimeInterval, sentAgo: TimeInterval, transcriptAgo: TimeInterval) {
        healthLock.withLock {
            let now = Date()
            return (now.timeIntervalSince(_capturedAt), now.timeIntervalSince(_sentAt), now.timeIntervalSince(_transcriptAt))
        }
    }

    // Mute the local microphone: the user's own voice is not captured or transcribed,
    // while system audio and the screen keep going. Guarded; the audio callback and the
    // UI toggle touch it from different threads. With no mic audio flowing, the mic VAD
    // gate hangover-closes its Soniox stream, so muting also stops mic transcription cost.
    private let muteLock = NSLock()
    private var _micMuted = false
    public var micMuted: Bool {
        get { muteLock.withLock { _micMuted } }
        set {
            muteLock.withLock { _micMuted = newValue }
            if newValue { onClearPartial?(.user) }   // drop any in-flight "You" partial
        }
    }

    // Accessors so the capture wiring (in another file) can reach the private state.
    func setClients(mic: SonioxClient, system: SonioxClient) { micClient = mic; systemClient = system }
    func setGates(mic: VadGatedSource?, system: VadGatedSource?) { micGate = mic; systemGate = system }
    func setAudioCapture(_ capture: AudioCapture) { audioCapture = capture }
    // Route audio through the VAD gate when present, else straight to the socket.
    func feedMic(_ data: Data) {
        if muteLock.withLock({ _micMuted }) { return }   // muted: drop mic audio entirely
        noteCaptured()
        // Echo detection at capture time: if the mic is loud WHILE the speaker was loud
        // a moment ago, mic and speaker overlap, i.e. the mic is hearing the speakers.
        if config.echoSuppression, AudioEnergy.isLoud(data, threshold: Float(config.echoSystemActiveRMS)) {
            let now = Date()
            echoLock.withLock {
                if now.timeIntervalSince(lastSystemLoudAt) < concurrencyWindow { lastConcurrentAt = now }
            }
        }
        if let g = micGate { g.feed(data) } else { micClient?.sendAudio(data); noteSent(); recordTranscription(bytes: data.count) }
    }
    func feedSystem(_ data: Data) {
        noteCaptured()
        // "The speaker is playing" comes from the raw system-audio energy at capture,
        // not the downstream VAD flag (which has gaps during reconnects and offset lag).
        if AudioEnergy.isLoud(data, threshold: Float(config.echoSystemActiveRMS)) {
            echoLock.withLock { lastSystemLoudAt = Date() }
        }
        if let g = systemGate {
            g.feed(data)
        } else {
            systemClient?.sendAudio(data); noteSent(); recordTranscription(bytes: data.count)
        }
    }
    // Called by the VAD gate when it actually forwards audio to Soniox.
    func recordSentBytes(_ bytes: Int) { recordTranscription(bytes: bytes) }

    public func stop() {
        // Pause is a privacy valve: tear down capture AND close the sockets.
        audioCapture?.stop()
        audioCapture = nil
        micGate?.stop(); systemGate?.stop()
        micGate = nil; systemGate = nil
        micClient?.close()
        systemClient?.close()
        micClient = nil
        systemClient = nil
    }

    // Resolve a display name: bind the active remote cluster to the on-screen
    // highlighted name (best effort), then look it up with the documented fallback.
    private func resolveName(source: SpeakerSource, cluster: String?) -> String {
        registryLock.withLock {
            if source == .remote, let cluster {
                registry.observe(activeCluster: cluster, highlightedName: highlightProvider?())
            }
            return registry.displayName(source: source, cluster: cluster)
        }
    }

    /// User-entered rename that sticks for the session.
    public func renameRemote(cluster: String, to name: String) {
        registryLock.withLock { registry.rename(cluster: cluster, to: name) }
    }
    public func renameUser(to name: String) {
        registryLock.withLock { registry.renameUser(to: name) }
    }

    // Emit a finalized utterance to the engine and a final line to the UI, with echo
    // suppression. A mic ("You") final is dropped as echo when EITHER it closely matches
    // a recent system-audio final (text match, precise) OR its utterance overlapped
    // speaker output (mic and speaker both loud at once, detected from capture-time
    // energy in feedMic). The energy overlap is robust to how the echo happened to be
    // transcribed and to which stream finalized first; genuine user speech in a quiet
    // room overlaps nothing, so it is kept and never delayed.
    func emitFinal(_ segment: SonioxSegment, source: SpeakerSource) {
        let now = Date()
        if source == .remote {
            echoLock.withLock { echo.noteSystem(segment.text, at: now) }
            Self.logEcho(side: "sys", text: segment.text, decision: "kept")
            deliverFinal(segment, source: .remote, at: now)
            return
        }
        // Mic (user) final: text-match first (precise), then capture-time concurrency.
        let (textEcho, overlapped): (Bool, Bool) = echoLock.withLock {
            (echo.isEcho(segment.text, at: now),
             now.timeIntervalSince(lastConcurrentAt) < overlapRecency)
        }
        if config.echoSuppression, textEcho || overlapped {
            Self.logEcho(side: "mic", text: segment.text, decision: textEcho ? "echo(text)" : "echo(overlap)")
            onClearPartial?(.user)   // clear the tentative "You" partial so the echo does not linger
            return
        }
        Self.logEcho(side: "mic", text: segment.text, decision: "kept")
        deliverFinal(segment, source: .user, at: now)
    }

    private func deliverFinal(_ segment: SonioxSegment, source: SpeakerSource, at now: Date) {
        let speaker = resolveName(source: source, cluster: segment.speakerLabel)
        // Carry Soniox's per-utterance detected language into the engine so a suggested
        // reply follows the language actually spoken, not the floor config.
        let event = TranscriptEvent(text: segment.text, speaker: speaker, timestamp: now,
                                    isFinal: true, language: segment.language)
        cont.yield(event)
        let lang = segment.language.flatMap { Language(rawValue: $0) }
        // The translation line is shown only when it differs from the original (when the
        // spoken language is already the interface language, Soniox returns the same text,
        // so there is nothing useful to show beneath).
        let translation = Self.usefulTranslation(segment.translation, original: segment.text)
        onLive?(LiveTranscriptLine(id: UUID().uuidString, speaker: speaker, source: source,
                                   cluster: segment.speakerLabel, text: segment.text, language: lang,
                                   translation: translation, isFinal: true))
    }

    // Drop a translation that just echoes the original (same language case) or is empty.
    public static func usefulTranslation(_ translation: String?, original: String) -> String? {
        guard let t = translation?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t.caseInsensitiveCompare(original.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame ? nil : t
    }

    // Set MAI_DEBUG_ECHO=1 to see both streams' finals, their arrival times, and the
    // echo decision, so the inter-arrival delta (which sizes the hold) is readable and
    // ordering-vs-divergence is distinguishable.
    nonisolated static func logEcho(side: String, text: String, decision: String) {
        guard ProcessInfo.processInfo.environment["MAI_DEBUG_ECHO"] == "1" else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let snippet = text.count > 48 ? String(text.prefix(48)) + "..." : text
        FileHandle.standardError.write(Data("Mai echo [\(stamp)] \(side): \(decision) | \"\(snippet)\"\n".utf8))
    }

    // Emit a live partial line to the UI only (never to the engine). The live
    // translation streams in alongside the partial (same Soniox stream), so it is as
    // instant as the transcript.
    func emitPartial(_ text: String, speakerLabel: String?, language: String?, translation: String?,
                     source: SpeakerSource, lineId: String) {
        guard !text.isEmpty else { return }
        let speaker = resolveName(source: source, cluster: speakerLabel)
        let lang = language.flatMap { Language(rawValue: $0) }
        onLive?(LiveTranscriptLine(id: lineId, speaker: speaker, source: source, cluster: speakerLabel,
                                   text: text, language: lang,
                                   translation: Self.usefulTranslation(translation, original: text), isFinal: false))
    }
}
