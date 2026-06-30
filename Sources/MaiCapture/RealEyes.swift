import Foundation
import MaiCore

// Real eyes: ScreenCaptureKit watches the chosen display at a low frame rate, a
// cheap dHash detects only meaningful settled changes, and Gemini reads the changed
// frame. Implements the MaiCore `Eyes` contract. The screen-watch and vision wiring
// are added in the eyes chunk; this owns the stream, the latest stored read, and the
// participant roster the speaker-naming layer reads.
public final class RealEyes: Eyes, @unchecked Sendable {
    let config: Config
    let secrets: Secrets
    private let _stream: AsyncStream<ScreenContentEvent>
    let cont: AsyncStream<ScreenContentEvent>.Continuation
    private let lock = NSLock()
    private var latest: ScreenContentEvent?
    private var highlightedName: String?
    private var roster: [String] = []
    var watcher: ScreenWatcher?
    public var usage: UsageMeter?   // spend meter: one vision read per settled screen change

    public init(config: Config, secrets: Secrets) {
        self.config = config
        self.secrets = secrets
        let made = AsyncStream<ScreenContentEvent>.makeStream()
        self._stream = made.stream
        self.cont = made.continuation
    }

    public func stream() -> AsyncStream<ScreenContentEvent> { _stream }

    public func currentScreen() async -> ScreenContentEvent? { lock.withLock { latest } }

    public func start() async throws { try await startWatching() }

    public func stop() {
        watcher?.stop()
        watcher = nil
    }

    // The current on-screen active-speaker name, for the speaker-naming correlation.
    public var currentHighlightedName: String? { lock.withLock { highlightedName } }
    public var currentRoster: [String] { lock.withLock { roster } }

    // Called by the screen-watch path on each settled read.
    func emit(content: String, subject: String? = nil, at: Date = Date()) {
        let event = ScreenContentEvent(content: content, timestamp: at, isChange: true, subject: subject)
        lock.withLock { latest = event }
        if let usage { Task { await usage.recordVision() } }
        cont.yield(event)
    }
    func updateNaming(roster: [String], highlighted: String?) {
        lock.withLock { self.roster = roster; self.highlightedName = highlighted }
    }
}
