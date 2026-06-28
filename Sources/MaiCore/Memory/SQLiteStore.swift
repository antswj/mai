import Foundation
import GRDB

// General-purpose, exportable local store. Everything said and shown is saved in
// a clean, self-contained schema so a user can export their own session data.
// Stored locally only (the .sqlite files are gitignored) with no external consumer.
// GRDB is the current, maintained Swift SQLite wrapper (v7.x, builds under CLT only).
public final class SQLiteStore: MemoryStore, SessionStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    startedAt TEXT NOT NULL,
                    endedAt TEXT,
                    interfaceLanguage TEXT NOT NULL,
                    floorLanguage TEXT NOT NULL,
                    meetingMode INTEGER NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS records (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT UNIQUE NOT NULL,
                    sessionId TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    language TEXT,
                    speaker TEXT,
                    content TEXT NOT NULL,
                    timestamp TEXT NOT NULL,
                    meta TEXT NOT NULL
                )
                """)
        }
    }

    // MARK: - SessionStore

    public func startSession(_ info: SessionInfo) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO sessions (id, startedAt, endedAt, interfaceLanguage, floorLanguage, meetingMode)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [info.id, Self.iso(info.startedAt), info.endedAt.map(Self.iso),
                                 info.interfaceLanguage, info.floorLanguage, info.meetingMode ? 1 : 0])
        }
    }

    public func endSession(id: String, endedAt: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET endedAt = ? WHERE id = ?",
                           arguments: [Self.iso(endedAt), id])
        }
    }

    // MARK: - MemoryStore

    public func save(_ r: MemoryRecord) throws {
        let metaJSON = Self.encodeMeta(r.meta)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO records (id, sessionId, kind, language, speaker, content, timestamp, meta)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [r.id, r.sessionId, r.kind, r.language, r.speaker, r.content, Self.iso(r.timestamp), metaJSON])
        }
    }

    /// Full session as clean, general-purpose JSON: { "session": {...}, "records": [...] }
    /// Records are returned in insertion order (the order Mai produced them).
    public func exportSession(_ sessionId: String) throws -> Data {
        try dbQueue.read { db in
            var sessionDict: [String: Any] = [:]
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [sessionId]) {
                sessionDict = [
                    "id": row["id"] as String? ?? sessionId,
                    "startedAt": row["startedAt"] as String? ?? "",
                    "endedAt": (row["endedAt"] as String?) as Any,
                    "interfaceLanguage": row["interfaceLanguage"] as String? ?? "",
                    "floorLanguage": row["floorLanguage"] as String? ?? "",
                    "meetingMode": (row["meetingMode"] as Int? ?? 0) == 1,
                ]
            } else {
                sessionDict = ["id": sessionId]
            }

            var records: [[String: Any]] = []
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM records WHERE sessionId = ? ORDER BY seq ASC", arguments: [sessionId])
            for row in rows {
                let metaStr: String = row["meta"] as String? ?? "{}"
                let meta = Self.decodeMeta(metaStr)
                records.append([
                    "id": row["id"] as String? ?? "",
                    "kind": row["kind"] as String? ?? "",
                    "language": (row["language"] as String?) as Any,
                    "speaker": (row["speaker"] as String?) as Any,
                    "content": row["content"] as String? ?? "",
                    "timestamp": row["timestamp"] as String? ?? "",
                    "meta": meta,
                ])
            }

            let payload: [String: Any] = ["session": sessionDict, "records": records]
            return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
    }

    // MARK: - Helpers

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    private static func encodeMeta(_ meta: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
    private static func decodeMeta(_ s: String) -> [String: String] {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }
}
