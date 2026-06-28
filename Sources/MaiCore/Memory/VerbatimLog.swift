import Foundation

// Append-only JSONL of the raw transcript and screen events, never deleted.
// Always-on capture is sensitive, so this stays local only and is gitignored.
public final class VerbatimLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(directory: String = "data", filename: String = "verbatim.jsonl") {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = enc
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    private struct Line<T: Codable>: Codable { let type: String; let sessionId: String; let event: T }

    public func appendTranscript(_ event: TranscriptEvent, sessionId: String) {
        write(Line(type: "transcript", sessionId: sessionId, event: event))
    }
    public func appendScreen(_ event: ScreenContentEvent, sessionId: String) {
        write(Line(type: "screen", sessionId: sessionId, event: event))
    }

    private func write<T: Codable>(_ line: Line<T>) {
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A) // newline
        lock.lock(); defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    public var path: String { url.path }
}
