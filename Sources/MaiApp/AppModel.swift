import Foundation
import SwiftUI
import MaiCore
import MaiCapture

// What the Face emits, carried over an AsyncStream so the actor-isolated engine can
// hand cards to the @MainActor model without unsafe cross-actor capture.
enum FaceEvent: Sendable {
    case surfaced(Card)
    case suppressed(Card, String)
}

final class StreamFace: Face, @unchecked Sendable {
    private let cont: AsyncStream<FaceEvent>.Continuation
    init(_ cont: AsyncStream<FaceEvent>.Continuation) { self.cont = cont }
    func render(_ card: Card) { cont.yield(.surfaced(card)) }
    func renderSuppressed(_ card: Card, why: String) { cont.yield(.suppressed(card, why)) }
}

// The Step-3 rich-card channel: the engine emits a skeleton then re-emits the same
// card (by id) as each enrichment part lands. Carried over an AsyncStream so the
// actor-isolated engine hands cards to the @MainActor model safely.
final class StreamRichSink: RichCardSink, @unchecked Sendable {
    private let cont: AsyncStream<RichCard>.Continuation
    init(_ cont: AsyncStream<RichCard>.Continuation) { self.cont = cont }
    func upsert(_ card: RichCard) { cont.yield(card) }
    func suppressed(headline: String, trigger: TriggerType, reason: String) {
        cont.yield(RichCard(trigger: trigger, timestamp: Date(), route: .pending, tier: .noise, score: 0,
                            headline: headline, pending: [], suppressed: true, note: reason))
    }
}

// Owns the engine and the capture session, and publishes the card stream and the
// live transcript to SwiftUI. Real ears and eyes are the default; when Mai is run
// unbundled (via `swift run`, no Screen Recording / Microphone grant) it degrades
// to simulated input so the app is still usable. A pause control tears capture down.
@MainActor
final class AppModel: ObservableObject {
    @Published var richItems: [RichCard] = []          // rich cards, newest first
    @Published var liveLines: [LiveTranscriptLine] = [] // transcript, oldest first (last = active)
    @Published var captureState: CaptureState = .starting
    @Published var showSuppressed: Bool
    @Published var useSimulated: Bool
    @Published var responseEnabled: Bool                // Part B toggle
    @Published var status: String = ""

    private(set) var config: Config
    private let secrets: Secrets
    private let store: MemoryStore
    private let verbatim: VerbatimLog
    private let bundled: Bool

    private var engine: Engine!
    private var realEars: RealEars?
    private var realEyes: RealEyes?
    private var simEars: SimulatedEars?
    private var simEyes: SimulatedEyes?
    private var runTask: Task<Void, Never>?
    private var faceTask: Task<Void, Never>?
    private var richTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var captureRetryTask: Task<Void, Never>?
    private var lastRestartAt = Date.distantPast

    let fixtures = ["meeting_ja_en.txt", "meeting_zh.txt", "casual.txt"]

    init() {
        let config = Config.load()
        self.config = config
        self.secrets = Secrets()
        self.store = (try? SQLiteStore(path: "data/mai.sqlite")) ?? StubStore()
        self.verbatim = VerbatimLog()
        self.showSuppressed = config.showSuppressedLog
        self.responseEnabled = config.responseEnabled
        // Real capture needs Screen Recording + Microphone, which only a signed .app
        // bundle can hold. Running unbundled (swift run) has no bundle id, so default
        // to the simulated dev path there. Force simulated with MAI_SIMULATED=1.
        let bundled = Bundle.main.bundleIdentifier != nil
        self.bundled = bundled
        self.useSimulated = ProcessInfo.processInfo.environment["MAI_SIMULATED"] == "1" || !bundled
        startSession()
    }

    // MARK: - Session lifecycle

    private func startSession() {
        let (faceStream, cont) = AsyncStream<FaceEvent>.makeStream()
        let face = StreamFace(cont)
        let (richStream, richCont) = AsyncStream<RichCard>.makeStream()
        let richSink = StreamRichSink(richCont)
        let llm = MaiFactory.makeLLM(config: config, secrets: secrets)
        let places = MaiFactory.makePlaces(config: config, secrets: secrets)
        let location = MaiFactory.makeLocation(config: config)
        let entity = MaiFactory.makeEntityLookup(config: config, secrets: secrets)
        let grounded = MaiFactory.makeGroundedSearch(config: config, secrets: secrets)
        let engine = Engine(config: config, llm: llm, places: places, location: location,
                            store: store, verbatim: verbatim, face: face,
                            richSink: richSink, entity: entity, grounded: grounded)
        self.engine = engine

        // The rich-card path (Step 3) drives the card UI. The Card/Face stream is kept
        // for any non-rich fallback but is unused while lookup is enabled.
        richTask = Task { [weak self] in
            for await card in richStream {
                guard let self else { continue }
                self.upsertRich(card)
            }
        }
        faceTask = Task { [weak self] in
            for await _ in faceStream { _ = self }   // drained; rich path is the UI
        }

        if useSimulated {
            let ears = SimulatedEars()
            let eyes = SimulatedEyes()
            simEars = ears; simEyes = eyes; realEars = nil; realEyes = nil
            runTask = Task { await engine.run(mergedStream(ears: ears, eyes: eyes)) }
            captureState = config.startPaused ? .paused : .simulated
            status = bundled
                ? "Simulated input (debug toggle). LLM: \(config.llmProvider). Floor: \(config.floorLanguage.rawValue)."
                : "Running unbundled: simulated input. Build Mai.app (./make-app.sh) for real capture."
        } else {
            let ears = RealEars(config: config, secrets: secrets)
            let eyes = RealEyes(config: config, secrets: secrets)
            realEars = ears; realEyes = eyes; simEars = nil; simEyes = nil
            ears.onLive = { [weak self] line in Task { @MainActor in self?.ingestLive(line) } }
            // Let the eyes feed the active-speaker name into the ears' naming layer.
            ears.highlightProvider = { [weak eyes] in eyes?.currentHighlightedName }
            runTask = Task { await engine.run(mergedStream(ears: ears, eyes: eyes)) }
            captureState = .starting
            status = "Starting capture. LLM: \(config.llmProvider). Floor: \(config.floorLanguage.rawValue)."
            if !config.startPaused { Task { await startCapture() } } else { captureState = .paused }
        }
    }

    private func stopSession() {
        runTask?.cancel(); runTask = nil
        faceTask?.cancel(); faceTask = nil
        richTask?.cancel(); richTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        captureRetryTask?.cancel(); captureRetryTask = nil
        realEars?.stop(); realEyes?.stop()
        simEars?.finish(); simEyes?.finish()
    }

    // Upsert a rich card by id: first emit inserts the skeleton (newest first), later
    // emits update it in place as enrichment parts resolve.
    private func upsertRich(_ card: RichCard) {
        if let idx = richItems.firstIndex(where: { $0.id == card.id }) {
            richItems[idx] = card
        } else {
            richItems.insert(card, at: 0)
            if richItems.count > 200 { richItems.removeLast(richItems.count - 200) }
        }
    }

    // Part B: flip the suggested-response toggle and rebuild the session so the
    // enricher picks up the new setting. Cards already shown are kept.
    func toggleResponse() {
        responseEnabled.toggle()
        config.responseEnabled = responseEnabled
        let keepSimulated = useSimulated
        stopSession()
        useSimulated = keepSimulated
        startSession()
        status = responseEnabled ? "Suggested responses on." : "Suggested responses off."
    }

    private func startCapture() async {
        guard let ears = realEars, let eyes = realEyes else { return }
        // Gate on BOTH permissions before any SCStream starts. Requesting the mic
        // here (not buried in the audio stream) is what makes the system prompt fire
        // and lists Mai under Privacy, Microphone.
        let perms = await CapturePermissions.ensure()
        guard perms.bothGranted else {
            FileHandle.standardError.write(Data("Mai: capture blocked, missing permission(s): \(perms.missing.joined(separator: ", "))\n".utf8))
            fallBackToSimulated(reason: Self.permissionMessage(perms))
            return
        }
        do {
            try await eyes.start()
            try await ears.start()
            ears.resetHealth()
            captureState = .capturing
            status = "Capturing. Speak near the mic; advance a slide to test the screen."
            startWatchdog()
        } catch {
            // Permissions were already granted (gated above), so this is a transient
            // capture error: retry automatically rather than dropping to simulated.
            captureState = .starting
            status = "Capture error: \(error.localizedDescription). Retrying automatically..."
            scheduleCaptureRetry()
        }
    }

    // Auto-retry real capture after a transient start failure, indefinitely (it is an
    // always-on app), on a delay so it never tight-loops. Stops if paused or switched
    // to simulated.
    private func scheduleCaptureRetry(after seconds: Double = 8) {
        captureRetryTask?.cancel()
        captureRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            guard !self.useSimulated, !self.isPaused, self.realEars != nil else { return }
            await self.startCapture()
        }
    }

    // Watchdog: keeps capture, transcription, and the card stream alive. Real audio
    // flows continuously even in silence, so "no audio at all" means the capture
    // stack died; "audio being sent but nothing transcribed back" means the Soniox
    // pipeline stalled. Either way it kicks the session. It never restarts merely
    // because the room is quiet, so it does not flap during normal pauses.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                await self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        guard captureState == .capturing, let ears = realEars else { return }
        guard Date().timeIntervalSince(lastRestartAt) > 30 else { return }   // backoff between kicks
        let h = ears.health()
        if h.capturedAgo > 12 {
            kick("capture stalled (no audio for \(Int(h.capturedAgo))s)")
        } else if h.sentAgo < 6 && h.transcriptAgo > 20 {
            // Audio is being sent but Soniox has gone quiet: reconnect the pipeline.
            kick("transcription stalled (audio flowing, no transcript for \(Int(h.transcriptAgo))s)")
        }
    }

    private func kick(_ why: String) {
        lastRestartAt = Date()
        FileHandle.standardError.write(Data("Mai watchdog: \(why); restarting capture.\n".utf8))
        status = "Recovering: \(why)."
        restartCapture()
    }

    // Tear the real-capture session down and bring it back up. Driven entirely by the
    // watchdog, automatically; there is no manual control. Cards and transcript
    // already shown are kept.
    private func restartCapture() {
        guard !useSimulated else { return }
        stopSession()
        useSimulated = false
        startSession()
    }

    private func fallBackToSimulated(reason: String) {
        stopSession()
        useSimulated = true
        startSession()                      // builds the simulated session
        captureState = .unavailable(reason) // override so the bar shows why capture is off
        status = reason
    }

    private static func permissionMessage(_ p: CapturePermissionStatus) -> String {
        var parts: [String] = []
        if !p.microphoneGranted {
            parts.append("Microphone access is required for live transcription. Please enable it in System Settings, Privacy and Security, Microphone.")
        }
        if !p.screenRecordingGranted {
            parts.append("Screen Recording access is required. Please enable Mai in System Settings, Privacy and Security, Screen and System Audio Recording, then relaunch Mai.app.")
        }
        parts.append("Using simulated input until then.")
        return parts.joined(separator: " ")
    }

    // MARK: - Pause (privacy valve): tears capture down and closes Soniox sockets

    var isPaused: Bool { captureState == .paused }
    var isCapturing: Bool { captureState == .capturing }

    func togglePause() { isPaused ? resume() : pause() }

    func pause() {
        realEars?.stop(); realEyes?.stop()
        captureState = .paused
        status = "Paused. Nothing is captured, transcribed, read, or stored."
    }

    func resume() {
        if realEars != nil {
            captureState = .starting
            Task { await startCapture() }
        } else {
            captureState = .simulated
            status = "Resumed (simulated input)."
        }
    }

    func toggleSimulated() {
        stopSession()
        liveLines.removeAll()
        useSimulated.toggle()
        startSession()
    }

    // MARK: - Live transcript ingestion (real path)

    private func ingestLive(_ line: LiveTranscriptLine) {
        guard !isPaused else { return }
        if line.isFinal {
            // Drop the in-flight partial for this source, append the settled line.
            liveLines.removeAll { $0.id == partialID(line.source) }
            liveLines.append(line)
            if liveLines.count > 200 { liveLines.removeFirst(liveLines.count - 200) }
        } else {
            // Upsert the single in-flight partial line for this source.
            if let idx = liveLines.firstIndex(where: { $0.id == partialID(line.source) }) {
                liveLines[idx] = lineWithID(line, partialID(line.source))
            } else {
                liveLines.append(lineWithID(line, partialID(line.source)))
            }
        }
    }
    private func partialID(_ source: SpeakerSource) -> String { "live-\(source.rawValue)" }
    private func lineWithID(_ line: LiveTranscriptLine, _ id: String) -> LiveTranscriptLine {
        LiveTranscriptLine(id: id, speaker: line.speaker, source: line.source, text: line.text,
                           language: line.language, translation: line.translation, isFinal: line.isFinal)
    }

    // MARK: - Simulated input (dev path)

    func injectLine(_ raw: String) {
        guard useSimulated, !isPaused else { return }
        let (speaker, text) = Self.parseSpeaker(raw)
        guard !text.isEmpty else { return }
        simEars?.injectLine(text, speaker: speaker)
        // Show the typed line in the transcript too, attributed to the user.
        let line = LiveTranscriptLine(id: UUID().uuidString, speaker: speaker ?? "You", source: .user,
                                      text: text, language: config.floorLanguage, isFinal: true)
        liveLines.append(line)
        if liveLines.count > 200 { liveLines.removeFirst(liveLines.count - 200) }
    }

    func injectScreen(_ text: String) {
        guard useSimulated, !isPaused else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        simEyes?.inject(t)
        status = "Screen updated (stored, surfaced when pointed at)."
    }

    // Manual speaker rename, persists for the session (real-capture path).
    func renameSpeaker(_ line: LiveTranscriptLine, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch line.source {
        case .user: realEars?.renameUser(to: trimmed)
        case .remote: if let cluster = line.cluster { realEars?.renameRemote(cluster: cluster, to: trimmed) }
        }
        // Reflect the new name on lines already shown for this speaker.
        for i in liveLines.indices where liveLines[i].speaker == line.speaker && liveLines[i].source == line.source {
            liveLines[i].speaker = trimmed
        }
    }

    func summarize() {
        Task {
            if let s = await engine.summarize() {
                let card = RichCard(trigger: .question, timestamp: Date(), route: .technical, tier: .medium,
                                    score: 1, headline: "Session summary", info: s, pending: [])
                self.upsertRich(card)
            }
        }
    }

    func loadFixture(_ name: String) {
        guard useSimulated, !isPaused else {
            status = "Fixtures replay in simulated mode only."; return
        }
        let paths = ["Tests/MaiCoreTests/Fixtures/\(name)", name]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            status = "Fixture not found: \(name)"; return
        }
        status = "Replaying \(name)..."
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        let ears = simEars, eyes = simEyes
        let floor = config.floorLanguage
        Task { [weak self] in
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                if t.hasPrefix("[SCREEN]") {
                    eyes?.inject(String(t.dropFirst("[SCREEN]".count)).trimmingCharacters(in: .whitespaces))
                } else {
                    let (speaker, body) = Self.parseSpeaker(t)
                    if body.isEmpty { continue }
                    ears?.injectLine(body, speaker: speaker)
                    await MainActor.run {
                        guard let self else { return }
                        self.liveLines.append(LiveTranscriptLine(id: UUID().uuidString, speaker: speaker ?? "You",
                                                                 source: .user, text: body, language: floor, isFinal: true))
                    }
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            await MainActor.run { self?.status = "Replayed \(name)." }
        }
    }

    static func parseSpeaker(_ raw: String) -> (String?, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.firstIndex(of: ":") {
            let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && name.count <= 24 && !name.contains(" ") && !rest.isEmpty {
                return (name, rest)
            }
        }
        return (nil, trimmed)
    }
}

final class StubStore: MemoryStore, @unchecked Sendable {
    func save(_ record: MemoryRecord) throws {}
    func exportSession(_ sessionId: String) throws -> Data { Data("{}".utf8) }
}
