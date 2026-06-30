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
        if let g = systemGate { g.feed(data) } else { systemClient?.sendAudio(data); noteSent(); recordTranscription(bytes: data.count) }
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

    // Emit a finalized utterance to the engine and a final line to the UI.
    func emitFinal(_ segment: SonioxSegment, source: SpeakerSource) {
        let now = Date()
        // Echo suppression: record system (remote) finals; drop a mic (user) final that
        // closely matches a recent system final (the speaker output picked up by the
        // mic). Genuine user speech has no matching recent system line, so it is kept.
        let isEcho: Bool = echoLock.withLock {
            switch source {
            case .remote: echo.noteSystem(segment.text, at: now); return false
            case .user: return echo.isEcho(segment.text, at: now)
            }
        }
        if isEcho {
            // The echo already streamed as a live "You" partial before finalizing, so
            // clear it; otherwise the dropped line lingers on screen.
            onClearPartial?(source)
            return
        }
        let speaker = resolveName(source: source, cluster: segment.speakerLabel)
        // Carry Soniox's per-utterance detected language into the engine so a suggested
        // reply follows the language actually spoken, not the floor config.
        let event = TranscriptEvent(text: segment.text, speaker: speaker, timestamp: now,
                                    isFinal: true, language: segment.language)
        cont.yield(event)
        let lang = segment.language.flatMap { Language(rawValue: $0) }
        onLive?(LiveTranscriptLine(id: UUID().uuidString, speaker: speaker, source: source,
                                   cluster: segment.speakerLabel, text: segment.text, language: lang, isFinal: true))
    }

    // Emit a live partial line to the UI only (never to the engine).
    func emitPartial(_ text: String, speakerLabel: String?, language: String?, source: SpeakerSource, lineId: String) {
        guard !text.isEmpty else { return }
        let speaker = resolveName(source: source, cluster: speakerLabel)
        let lang = language.flatMap { Language(rawValue: $0) }
        onLive?(LiveTranscriptLine(id: lineId, speaker: speaker, source: source,
                                   cluster: speakerLabel, text: text, language: lang, isFinal: false))
    }
}
