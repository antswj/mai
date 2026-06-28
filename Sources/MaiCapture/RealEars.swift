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
    // The app wires this to the eyes' current active-speaker name, for naming.
    public var highlightProvider: (@Sendable () -> String?)?
    // Maps diarization clusters to real names; guarded because mic and system
    // Soniox callbacks can touch it concurrently.
    private var registry = SpeakerRegistry()
    private let registryLock = NSLock()

    // Filled in the capture chunk.
    private var micClient: SonioxClient?
    private var systemClient: SonioxClient?
    private var audioCapture: AudioCapture?

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

    // Accessors so the capture wiring (in another file) can reach the private state.
    func setClients(mic: SonioxClient, system: SonioxClient) { micClient = mic; systemClient = system }
    func setAudioCapture(_ capture: AudioCapture) { audioCapture = capture }
    func sendMic(_ data: Data) { micClient?.sendAudio(data) }
    func sendSystem(_ data: Data) { systemClient?.sendAudio(data) }

    public func stop() {
        // Pause is a privacy valve: tear down capture AND close the sockets.
        audioCapture?.stop()
        audioCapture = nil
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
        let speaker = resolveName(source: source, cluster: segment.speakerLabel)
        let event = TranscriptEvent(text: segment.text, speaker: speaker, timestamp: Date(), isFinal: true)
        cont.yield(event)
        let lang = segment.language.flatMap { Language(rawValue: $0) }
        onLive?(LiveTranscriptLine(id: UUID().uuidString, speaker: speaker, source: source,
                                   text: segment.text, language: lang, isFinal: true))
    }

    // Emit a live partial line to the UI only (never to the engine).
    func emitPartial(_ text: String, speakerLabel: String?, language: String?, source: SpeakerSource, lineId: String) {
        guard !text.isEmpty else { return }
        let speaker = resolveName(source: source, cluster: speakerLabel)
        let lang = language.flatMap { Language(rawValue: $0) }
        onLive?(LiveTranscriptLine(id: lineId, speaker: speaker, source: source,
                                   text: text, language: lang, isFinal: false))
    }
}
