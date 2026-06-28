import Foundation
import MaiCore

// One Soniox real-time connection (one per audio source). Opens the WebSocket,
// sends the JSON config first, streams raw PCM16 binary frames, parses token
// messages through the pure SonioxSegmenter, and reports updates. Foundation only
// (URLSessionWebSocketTask), so it is exercised live by the smoke test with audio
// from `say`, no microphone or ScreenCaptureKit required.
public final class SonioxClient: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable (SonioxSegmenter.Update) -> Void

    private static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    private let configJSON: String
    private let onUpdate: UpdateHandler
    private let onError: (@Sendable (String) -> Void)?
    private let segmenter = SonioxSegmenter()
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var keepalive: Task<Void, Never>?
    private let lock = NSLock()
    private var closed = false

    public init(configJSON: String, onUpdate: @escaping UpdateHandler, onError: (@Sendable (String) -> Void)? = nil) {
        self.configJSON = configJSON
        self.onUpdate = onUpdate
        self.onError = onError
        self.session = URLSession(configuration: .default)
    }

    public func connect() {
        let t = session.webSocketTask(with: Self.endpoint)
        lock.withLock { task = t; closed = false }
        t.resume()
        t.send(.string(configJSON)) { [weak self] err in
            if let err { self?.onError?("soniox config send: \(err.localizedDescription)") }
        }
        receiveLoop()
        startKeepalive()
    }

    /// Stream a chunk of raw signed-16-bit little-endian PCM.
    public func sendAudio(_ data: Data) {
        guard let t = lock.withLock({ task }) else { return }
        t.send(.data(data)) { [weak self] err in
            if let err { self?.onError?("soniox audio send: \(err.localizedDescription)") }
        }
    }

    /// Ask Soniox to finalize everything buffered so far (no end of stream).
    public func finalize() {
        lock.withLock { task }?.send(.string(#"{"type":"finalize"}"#)) { _ in }
    }

    /// Close the connection (used by pause and on stream end). Sends an empty frame
    /// so the server flushes, then cancels.
    public func close() {
        let t: URLSessionWebSocketTask? = lock.withLock {
            if closed { return nil }
            closed = true
            let current = task
            task = nil
            return current
        }
        guard let t else { return }
        keepalive?.cancel(); keepalive = nil
        t.send(.string("")) { _ in }
        t.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - private

    private func receiveLoop() {
        guard let t = lock.withLock({ task }) else { return }
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                if !self.lock.withLock({ self.closed }) {
                    self.onError?("soniox receive: \(err.localizedDescription)")
                }
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data): if let s = String(data: data, encoding: .utf8) { self.handle(s) }
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let msg = SonioxMessage.parse(text) else { return }
        if let code = msg.errorCode { onError?("soniox error \(code): \(msg.errorMessage ?? "")") }
        let update = segmenter.ingest(msg)
        onUpdate(update)
    }

    private func startKeepalive() {
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard let self, !self.lock.withLock({ self.closed }) else { return }
                self.lock.withLock { self.task }?.send(.string(#"{"type":"keepalive"}"#)) { _ in }
            }
        }
    }
}
