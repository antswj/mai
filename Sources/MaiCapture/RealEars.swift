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
    // When system audio was last actually playing (the system VAD gate forwarded voice).
    // The mic-final hold is gated on this, so the user's own speech is only delayed
    // while the speaker is actually producing sound (when echo is possible), not in a
    // quiet room. Continuous capture does NOT count; only forwarded (voiced) audio.
    private var lastSystemActiveAt = Date.distantPast
    func noteSystemActive() { echoLock.withLock { lastSystemActiveAt = Date() } }

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

    // Accessors so the capture wiring (in another file) can reach the private state.
    func setClients(mic: SonioxClient, system: SonioxClient) { micClient = mic; systemClient = system }
    func setGates(mic: VadGatedSource?, system: VadGatedSource?) { micGate = mic; systemGate = system }
    func setAudioCapture(_ capture: AudioCapture) { audioCapture = capture }
    // Route audio through the VAD gate when present, else straight to the socket.
    func feedMic(_ data: Data) {
        noteCaptured()
        if let g = micGate { g.feed(data) } else { micClient?.sendAudio(data); noteSent(); recordTranscription(bytes: data.count) }
    }
    func feedSystem(_ data: Data) {
        noteCaptured()
        if let g = systemGate {
            g.feed(data)   // the gate calls noteSystemActive via onSent only when it forwards voiced audio
        } else {
            // VAD off: system audio streams continuously, so treat it as active.
            systemClient?.sendAudio(data); noteSent(); recordTranscription(bytes: data.count); noteSystemActive()
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
    // suppression. The two streams (mic and system) finalize independently, so a mic
    // echo of system audio can arrive in EITHER order relative to the matching system
    // final. To catch both orders without dropping genuine user speech:
    //  - a system final is recorded immediately for matching, and delivered.
    //  - a mic final is checked against already-recorded system finals (forward case);
    //    and if system audio is currently playing, it is HELD briefly and re-checked,
    //    so a system final that finalizes slightly later still matches (reverse case).
    //  - if no system audio is active, the mic final is delivered immediately (a quiet
    //    room: genuine user speech is never delayed).
    func emitFinal(_ segment: SonioxSegment, source: SpeakerSource) {
        let now = Date()
        if source == .remote {
            echoLock.withLock { echo.noteSystem(segment.text, at: now) }
            Self.logEcho(side: "sys", text: segment.text, decision: "kept")
            deliverFinal(segment, source: .remote, at: now)
            return
        }
        // Mic (user) final.
        let (immediateEcho, systemActive): (Bool, Bool) = echoLock.withLock {
            (echo.isEcho(segment.text, at: now),
             now.timeIntervalSince(lastSystemActiveAt) < 3.0)
        }
        if immediateEcho {
            Self.logEcho(side: "mic", text: segment.text, decision: "echo(forward)")
            onClearPartial?(.user)
            return
        }
        guard config.echoSuppression, systemActive else {
            Self.logEcho(side: "mic", text: segment.text, decision: systemActive ? "kept" : "kept(no-system)")
            deliverFinal(segment, source: .user, at: now)
            return
        }
        // System audio is playing: hold the mic final, clearing the tentative partial so
        // an echo never flashes on screen, then re-check after the hold (a matching
        // system final may finalize during it). Genuine user speech survives the hold.
        onClearPartial?(.user)
        let hold = max(0.3, config.echoHoldSeconds)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard let self else { return }
            let echoNow = self.echoLock.withLock { self.echo.isEcho(segment.text, at: now) }
            if echoNow {
                Self.logEcho(side: "mic", text: segment.text, decision: "echo(held \(hold)s)")
            } else {
                Self.logEcho(side: "mic", text: segment.text, decision: "kept(held \(hold)s)")
                self.deliverFinal(segment, source: .user, at: now)
            }
        }
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
