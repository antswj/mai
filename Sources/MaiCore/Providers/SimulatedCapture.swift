import Foundation

// Simulated ears and eyes: real implementations of the capture contracts, backed by
// AsyncStreams. They stand in for real audio and ScreenCaptureKit (which arrive in a
// later step behind these same contracts). Drive them with inject(...); the engine
// consumes the merged stream via Engine.run(mergedStream(ears:eyes:)) exactly as it
// will with real capture, so the always-on path is the same path real capture uses.

public final class SimulatedEars: Ears, @unchecked Sendable {
    private let _stream: AsyncStream<TranscriptEvent>
    private let cont: AsyncStream<TranscriptEvent>.Continuation
    public init() { (_stream, cont) = AsyncStream<TranscriptEvent>.makeStream() }
    public func stream() -> AsyncStream<TranscriptEvent> { _stream }

    public func inject(_ event: TranscriptEvent) { cont.yield(event) }
    public func injectLine(_ text: String, speaker: String? = nil, at: Date = Date()) {
        cont.yield(TranscriptEvent(text: text, speaker: speaker, timestamp: at, isFinal: true))
    }
    public func finish() { cont.finish() }
}

public final class SimulatedEyes: Eyes, @unchecked Sendable {
    private let _stream: AsyncStream<ScreenContentEvent>
    private let cont: AsyncStream<ScreenContentEvent>.Continuation
    private let lock = NSLock()
    private var latest: ScreenContentEvent?
    public init() { (_stream, cont) = AsyncStream<ScreenContentEvent>.makeStream() }
    public func stream() -> AsyncStream<ScreenContentEvent> { _stream }
    public func currentScreen() async -> ScreenContentEvent? {
        lock.withLock { latest }
    }

    public func inject(_ content: String, at: Date = Date(), isChange: Bool = true) {
        let event = ScreenContentEvent(content: content, timestamp: at, isChange: isChange)
        lock.withLock { latest = event }
        cont.yield(event)
    }
    public func finish() { cont.finish() }
}
