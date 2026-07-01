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
    // Pinned cards (kept separately so the 200-cap on richItems can never evict them;
    // they never auto-dismiss). The carousel shows one at a time. notedCardIds marks
    // pinned cards to be written into the exported meeting notes.
    @Published var pinnedCards: [RichCard] = []
    @Published var carouselIndex: Int = 0
    @Published var notedCardIds: Set<String> = []
    private var notedCardLines: [String: String] = [:]   // card id -> one-line note for export
    @Published var liveLines: [LiveTranscriptLine] = [] // transcript, oldest first (last = active)
    @Published var captureState: CaptureState = .starting
    @Published var showSuppressed: Bool
    @Published var useSimulated: Bool
    @Published var responseEnabled: Bool                // Part B toggle
    @Published var translationOn: Bool                  // live-transcript translation toggle
    @Published var micMuted: Bool = false               // mute the local mic (keep system audio + screen)
    @Published var expandedCardIds: Set<String> = []    // HUD cards expanded to full detail
    @Published var status: String = ""
    @Published var headphonesTip = false                // one-time tip: headphones remove echo

    // Step 3: chat assistant, notes pipeline, modes, spend, onboarding and keys.
    @Published var chat: [ChatMessage] = []
    @Published var chatOpen = false
    @Published var assistantThinking = false
    @Published var noteTaking = false
    @Published var notesProcessing: String?            // visible processing state on stop
    @Published var savedMeetings: [MeetingIndexEntry] = []
    @Published var lastSavedMeeting: MeetingExport?
    @Published var spend = SpendEstimate(transcription: 0, vision: 0, model: 0, search: 0, total: 0)
    @Published var missionPinned = false
    @Published var appWindowOpen = false
    @Published var notesFolder: URL?
    @Published var onboardingComplete: Bool
    @Published var keyPresence: [String: Bool] = [:]   // which known keys are set
    private(set) var summonedAt = Date.distantPast
    // Last time anything happened (a partial line, a final line, or a card). Drives the
    // HUD idle timer so it rides through the natural pauses of a conversation.
    private(set) var lastActivityAt = Date()

    let rates = UsageRates()
    private var assistant: AssistantProvider!
    private var notes: NotesStore!
    private var usage: UsageMeter!
    // The live-transcript translation provider (Soniox same-stream now; swappable).
    private(set) lazy var translation: TranslationProvider =
        TranslationFactory.make(engine: config.translationEngine, target: config.interfaceLanguage)

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
        // A shipped app launched from /Applications has cwd "/", so repo-relative
        // "data/" would not persist. Use Application Support/Mai when bundled; keep
        // the repo's "data/" for `swift run` from the source tree.
        let bundled = Bundle.main.bundleIdentifier != nil
        self.bundled = bundled
        let dataDir = Self.dataDirectory(bundled: bundled)
        self.store = (try? SQLiteStore(path: dataDir + "/mai.sqlite")) ?? StubStore()
        self.verbatim = VerbatimLog(directory: dataDir)
        self.showSuppressed = config.showSuppressedLog
        self.responseEnabled = config.responseEnabled
        self.translationOn = config.sttTranslation
        self.onboardingComplete = UserDefaults.standard.bool(forKey: "mai.onboardingComplete")
        // Running unbundled (swift run) has no bundle id, so default to the simulated
        // dev path there. Force simulated with MAI_SIMULATED=1.
        self.useSimulated = ProcessInfo.processInfo.environment["MAI_SIMULATED"] == "1" || !bundled

        // The assistant, notes pipeline, and usage meter persist across capture
        // restarts (a watchdog restart must not reset accumulated notes).
        let meter = UsageMeter(storeURL: URL(fileURLWithPath: dataDir + "/mai-usage.json"))
        self.usage = meter
        let baseLLM = MeteredLLM(MaiFactory.makeLLM(config: config, secrets: secrets), meter: meter)
        self.notes = NotesStore(llm: baseLLM, model: config.drafterModel, interface: config.interfaceLanguage)
        self.assistant = AnthropicAssistant(llm: baseLLM, model: config.drafterModel, interface: config.interfaceLanguage)

        self.notesFolder = Self.resolveNotesFolder()
        refreshKeyPresence()
        startSession()
        refreshSavedMeetings()
        Task { await refreshSpend() }
    }

    // MARK: - Session lifecycle

    private func startSession() {
        let (faceStream, cont) = AsyncStream<FaceEvent>.makeStream()
        let face = StreamFace(cont)
        let (richStream, richCont) = AsyncStream<RichCard>.makeStream()
        let richSink = StreamRichSink(richCont)
        let llm = MeteredLLM(MaiFactory.makeLLM(config: config, secrets: secrets), meter: usage)
        let places = MaiFactory.makePlaces(config: config, secrets: secrets)
        let location = MaiFactory.makeLocation(config: config)
        let entity = MaiFactory.makeEntityLookup(config: config, secrets: secrets)
        let grounded = MeteredGrounded(MaiFactory.makeGroundedSearch(config: config, secrets: secrets), meter: usage)
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
            ears.usage = usage; eyes.usage = usage
            ears.micMuted = micMuted   // survive watchdog/auto-retry session rebuilds
            realEars = ears; realEyes = eyes; simEars = nil; simEyes = nil
            ears.onLive = { [weak self] line in Task { @MainActor in self?.ingestLive(line) } }
            ears.onClearPartial = { [weak self] source in Task { @MainActor in self?.clearPartial(source) } }
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
        lastActivityAt = Date()   // a surfacing card counts as activity
        if let idx = richItems.firstIndex(where: { $0.id == card.id }) {
            richItems[idx] = card
        } else {
            richItems.insert(card, at: 0)
            if richItems.count > 200 { richItems.removeLast(richItems.count - 200) }
        }
        // Keep a pinned copy fresh as its enrichment lands (it lives outside richItems).
        if let pidx = pinnedCards.firstIndex(where: { $0.id == card.id }) { pinnedCards[pidx] = card }
    }

    // MARK: - Pinned cards (Part 3)

    // Flowing cards = the stream minus the pinned ones (pinned moved into the carousel).
    var flowingCards: [RichCard] {
        let pinned = Set(pinnedCards.map { $0.id })
        let items = showSuppressed ? richItems : richItems.filter { !$0.suppressed }
        return items.filter { !pinned.contains($0.id) }
    }

    func isPinned(_ id: String) -> Bool { pinnedCards.contains { $0.id == id } }

    func pin(_ card: RichCard) {
        guard !isPinned(card.id) else { return }
        pinnedCards.append(card)
        carouselIndex = Carousel.afterPin(newCount: pinnedCards.count)   // show the newly pinned one
    }

    func unpin(_ id: String) {
        guard let removed = pinnedCards.firstIndex(where: { $0.id == id }) else { return }
        pinnedCards.remove(at: removed)
        notedCardIds.remove(id); notedCardLines[id] = nil
        carouselIndex = Carousel.afterUnpin(removedIndex: removed, current: carouselIndex, newCount: pinnedCards.count)
    }

    func carouselNext() { carouselIndex = Carousel.next(carouselIndex, count: pinnedCards.count) }
    func carouselPrev() { carouselIndex = Carousel.prev(carouselIndex, count: pinnedCards.count) }

    // Mark a pinned card to be written into the exported meeting notes (toggle).
    func toggleNoteCard(_ card: RichCard) {
        if notedCardIds.contains(card.id) {
            notedCardIds.remove(card.id); notedCardLines[card.id] = nil
        } else {
            notedCardIds.insert(card.id); notedCardLines[card.id] = card.noteLine()
        }
    }

    func isNoted(_ id: String) -> Bool { notedCardIds.contains(id) }

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

    // Part 1: flip the live-transcript translation toggle and rebuild the session so the
    // Soniox stream reconnects with or without the translation block (the VAD reconnect
    // and pre-roll handle the switch without clipping). Translation rides the same stream
    // so it is as instant as the transcript, and never appears in the cards.
    func toggleTranslation() {
        translationOn.toggle()
        config.sttTranslation = translationOn
        let keepSimulated = useSimulated
        stopSession()
        useSimulated = keepSimulated
        startSession()
        status = translationOn ? "Translation on (\(config.interfaceLanguage.rawValue))." : "Translation off."
    }

    // Apply a settings change to the config and rebuild the session so it takes effect.
    // Accumulated notes, chat, and saved meetings persist (they live outside the session).
    func updateConfig(_ mutate: (inout Config) -> Void) {
        var c = config; mutate(&c); config = c
        responseEnabled = c.responseEnabled
        let keepSimulated = useSimulated
        stopSession()
        useSimulated = keepSimulated
        startSession()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try LoginItem.enable() } else { try LoginItem.disable() } }
        catch { status = "Could not change Login Item: \(error.localizedDescription)" }
    }
    var launchAtLogin: Bool { LoginItem.isEnabled }

    // Show once: headphones remove speaker-to-mic echo entirely. The transcript-level
    // suppression works without them; this is just the cleanest-separation tip.
    private func maybeShowHeadphonesTip() {
        guard !UserDefaults.standard.bool(forKey: "mai.headphonesTipShown") else { return }
        UserDefaults.standard.set(true, forKey: "mai.headphonesTipShown")
        headphonesTip = true
    }
    func dismissHeadphonesTip() { headphonesTip = false }

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
            maybeShowHeadphonesTip()
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

    // Mute the local mic only (system audio and the screen keep going). A no-op in
    // simulated mode beyond flipping the indicator.
    func toggleMute() {
        micMuted.toggle()
        realEars?.micMuted = micMuted
        status = micMuted ? "Microphone muted (your voice is not captured)." : "Microphone unmuted."
    }

    // Expand or collapse a card in Mission mode to show its full detail and image.
    func toggleExpand(_ id: String) {
        if expandedCardIds.contains(id) { expandedCardIds.remove(id) } else { expandedCardIds.insert(id) }
    }
    func isExpanded(_ id: String) -> Bool { expandedCardIds.contains(id) }

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
        lastActivityAt = Date()   // any speech, even a mid-sentence partial, is activity
        if line.isFinal {
            // Drop the in-flight partial for this source, append the settled line.
            liveLines.removeAll { $0.id == partialID(line.source) }
            liveLines.append(line)
            if liveLines.count > 200 { liveLines.removeFirst(liveLines.count - 200) }
            feedNote(line)
            translateLineIfNeeded(line)
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
    // Remove the in-flight partial for a source without appending a final. Used when a
    // mic echo final is dropped, so the already-shown "You" partial does not linger.
    private func clearPartial(_ source: SpeakerSource) {
        liveLines.removeAll { $0.id == partialID(source) }
    }
    private func lineWithID(_ line: LiveTranscriptLine, _ id: String) -> LiveTranscriptLine {
        LiveTranscriptLine(id: id, speaker: line.speaker, source: line.source, text: line.text,
                           language: line.language, translation: line.translation, isFinal: line.isFinal)
    }

    // The TranslationProvider seam. For the Soniox provider (inline) the translation
    // already rode the stream and is on the line, so this is a no-op. A future per-line
    // provider (inlineOnTranscriptStream == false) translates the finalized line here and
    // fills it in, with no other change to the app. Selected by config.translationEngine.
    private func translateLineIfNeeded(_ line: LiveTranscriptLine) {
        guard translationOn, !translation.inlineOnTranscriptStream,
              line.isFinal, line.translation == nil else { return }
        let id = line.id, text = line.text, from = line.language, provider = translation
        Task { [weak self] in
            guard let translated = await provider.translate(line: text, from: from), !translated.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                if let idx = self.liveLines.firstIndex(where: { $0.id == id }) {
                    var l = self.liveLines[idx]
                    l.translation = translated
                    self.liveLines[idx] = l
                }
            }
        }
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
        feedNote(line)
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
                        let l = LiveTranscriptLine(id: UUID().uuidString, speaker: speaker ?? "You",
                                                   source: .user, text: body, language: floor, isFinal: true)
                        self.liveLines.append(l)
                        self.feedNote(l)
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

    // MARK: - Notes feeding

    @Published var keyStatus: [String: String] = [:]
    var onMeetingFinished: ((MeetingExport) -> Void)?

    private func feedNote(_ line: LiveTranscriptLine) {
        guard noteTaking, line.isFinal else { return }
        let ml = MeetingLine(speaker: line.speaker, isUser: line.source == .user, text: line.text,
                             timestamp: Date(), language: line.language?.rawValue)
        Task { [notes] in await notes!.add(ml) }
    }

    // The meeting transcript so far, for assistant context (order-preserving).
    private func meetingTranscript() -> [MeetingLine] {
        liveLines.filter { $0.isFinal && !$0.id.hasPrefix("live-") }
            .map { MeetingLine(speaker: $0.speaker, isUser: $0.source == .user, text: $0.text,
                               timestamp: Date(), language: $0.language?.rawValue) }
    }

    // MARK: - Chat with the assistant

    func openChat() { chatOpen = true; Task { [engine] in await engine?.setChatOpen(true) } }
    func closeChat() { chatOpen = false; Task { [engine] in await engine?.setChatOpen(false) } }

    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.append(ChatMessage(role: .user, text: trimmed))

        // "note this down" folds the item into the running meeting notes.
        if let item = AssistantContext.noteRequest(trimmed) {
            if noteTaking {
                Task { [notes] in await notes!.note(item) }
                chat.append(ChatMessage(role: .assistant, text: item.isEmpty ? "Noted." : "Noted: \(item)"))
            } else {
                chat.append(ChatMessage(role: .assistant, text: "Turn on note-taking first, then I can add that to the notes."))
            }
            return
        }

        let transcript = meetingTranscript()
        let history = chat
        assistantThinking = true
        Task { [assistant] in
            let reply = (try? await assistant!.reply(to: trimmed, transcript: transcript, history: history, screen: nil))
                ?? "Sorry, I could not reach the assistant just now."
            await MainActor.run {
                self.chat.append(ChatMessage(role: .assistant, text: reply))
                self.assistantThinking = false
            }
        }
    }

    // MARK: - Note-taking pipeline

    func toggleNoteTaking() { noteTaking ? stopNoteTaking() : startNoteTaking() }

    func startNoteTaking() {
        Task { [notes] in await notes!.start(now: Date()) }
        noteTaking = true
        status = "Note-taking on. Mai is capturing the meeting."
    }

    func stopNoteTaking() {
        noteTaking = false
        notesProcessing = NotesStore.Stage.reviewing.rawValue
        let folder = notesFolder
        // Noted pinned cards are written into the export alongside the transcript notes.
        let extraNoted = notedCardIds.compactMap { notedCardLines[$0] }
        Task { [notes] in
            let export = await notes!.stop(now: Date(), folder: folder, extraNoted: extraNoted, onStage: { stage in
                Task { @MainActor in self.notesProcessing = (stage == .done) ? nil : stage.rawValue }
            })
            await MainActor.run {
                self.notesProcessing = nil
                if let export {
                    self.lastSavedMeeting = export
                    self.refreshSavedMeetings()
                    self.status = folder == nil
                        ? "Wrote up \"\(export.title)\" (choose a notes folder in Settings to save it)."
                        : "Saved meeting: \(export.title)"
                    self.onMeetingFinished?(export)   // phase B: a meeting just finished
                } else {
                    self.status = "Nothing to save (no transcript was captured)."
                }
            }
        }
    }

    // MARK: - Saved meetings and spend

    func refreshSavedMeetings() {
        guard let folder = notesFolder else { savedMeetings = []; return }
        savedMeetings = MeetingIndexEntry.load(from: folder.appendingPathComponent("mai-meetings.json"))
    }

    func openSavedMeeting(_ entry: MeetingIndexEntry) {
        guard let folder = notesFolder else { return }
        NSWorkspace.shared.open(folder.appendingPathComponent(entry.docxFileName))
    }

    func refreshSpend() async {
        let counts = await usage.snapshot()
        let est = SpendMath.estimate(counts, rates: rates)
        await MainActor.run { self.spend = est }
    }

    // MARK: - Keychain keys

    func refreshKeyPresence() {
        var p: [String: Bool] = [:]
        for k in Secrets.knownKeys { p[k] = secrets.get(k) != nil }
        keyPresence = p
    }

    func saveKey(_ value: String, for key: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { try? Keychain.delete(account: key) } else { try? Keychain.save(v, account: key) }
        refreshKeyPresence()
        keyStatus[key] = v.isEmpty ? "Not set" : "Set"
    }

    // A quick live validation, with a clear message instead of a silent failure.
    func validateKeys() {
        keyStatus["__validating"] = "Checking..."
        let cfg = config; let sec = secrets
        Task {
            var results: [String: String] = [:]
            for key in Secrets.knownKeys {
                guard sec.get(key) != nil else { results[key] = "Not set"; continue }
                results[key] = await Self.validate(key: key, config: cfg, secrets: sec)
            }
            await MainActor.run {
                self.keyStatus = results
                let bad = results.filter { $0.value != "OK" && $0.value != "Set" && $0.value != "Not set" }
                self.status = bad.isEmpty ? "Keys checked." : "Key issues: " + bad.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            }
        }
    }

    private static func validate(key: String, config: Config, secrets: Secrets) async -> String {
        switch key {
        case "ANTHROPIC_API_KEY":
            guard let k = secrets.get(key) else { return "Not set" }
            do { _ = try await AnthropicLLM(apiKey: k).complete(system: "Reply with one word.", user: "ok", model: config.classifierModel); return "OK" }
            catch { return Self.classify(error) }
        default:
            // Other keys are present; they are validated on first real use.
            return secrets.get(key) != nil ? "Set" : "Not set"
        }
    }

    private static func classify(_ error: Error) -> String {
        let m = error.localizedDescription.lowercased()
        if m.contains("401") || m.contains("invalid") || m.contains("authentication") { return "Invalid key" }
        if m.contains("402") || m.contains("balance") || m.contains("credit") || m.contains("quota") { return "Out of balance" }
        return "Could not verify"
    }

    // MARK: - Notes folder (security-scoped bookmark; non-sandboxed needs no scope)

    func pickNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where Mai saves meeting notes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "mai.notesFolderBookmark")
        }
        notesFolder = url
        refreshSavedMeetings()
    }

    // The local data directory for the session store, raw log, and usage counts.
    // Application Support/Mai for a shipped app; the repo's data/ for `swift run`.
    static func dataDirectory(bundled: Bool) -> String {
        if bundled, let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("Mai", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.path
        }
        return "data"
    }

    static func resolveNotesFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "mai.notesFolderBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let refreshed = try? url.bookmarkData() { UserDefaults.standard.set(refreshed, forKey: "mai.notesFolderBookmark") }
        return url
    }

    func completeOnboarding() {
        onboardingComplete = true
        UserDefaults.standard.set(true, forKey: "mai.onboardingComplete")
    }

    @Published var permissionStatus = "Not requested"
    func requestPermissions() {
        permissionStatus = "Requesting\u{2026}"
        Task {
            let p = await CapturePermissions.ensure()
            await MainActor.run {
                self.permissionStatus = p.bothGranted ? "Granted"
                    : "Still missing: \(p.missing.joined(separator: ", ")). Grant in System Settings, Privacy and Security, then relaunch."
            }
        }
    }

    // MARK: - Modes (Mission HUD vs the full app) and the summon hotkey

    func summonMission() { summonedAt = Date(); objectWillChange.send() }
    func togglePinned() { missionPinned.toggle() }

    // The pure HUD show/hide decision, evaluated from current app state. The AppDelegate
    // polls this to slide the panel in and out.
    var shouldShowHUD: Bool {
        let hasCards = richItems.contains { !$0.suppressed && Date().timeIntervalSince($0.timestamp) < 30 }
        let summoned = chatOpen || Date().timeIntervalSince(summonedAt) < 8
        return HUDActivity.shouldShow(HUDActivityInput(
            noteTaking: noteTaking, hasActiveCards: hasCards,
            secondsSinceActivity: Date().timeIntervalSince(lastActivityAt),
            summoned: summoned, pinned: missionPinned, appWindowOpen: appWindowOpen, paused: isPaused))
    }
}

final class StubStore: MemoryStore, @unchecked Sendable {
    func save(_ record: MemoryRecord) throws {}
    func exportSession(_ sessionId: String) throws -> Data { Data("{}".utf8) }
}
