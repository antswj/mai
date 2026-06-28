import Foundation

// Session export: a feature any user can use to get their own session data out as
// clean, general-purpose JSON. It delegates to the store and adds nothing
// proprietary. There is no external sync in this open project.
//
// JSON shape (sync-ready and self-describing):
// {
//   "session": {
//     "id": String, "startedAt": ISO8601, "endedAt": ISO8601|null,
//     "interfaceLanguage": "en"|"ja"|"zh", "floorLanguage": "...", "meetingMode": Bool
//   },
//   "records": [
//     { "id": String, "kind": "transcript"|"screen"|"card"|"note"|"summary",
//       "language": String|null, "speaker": String|null, "content": String,
//       "timestamp": ISO8601, "meta": { String: String } },
//     ...   // in the order Mai produced them
//   ]
// }
public struct SyncExport: Sendable {
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }

    public func exportSession(_ sessionId: String) throws -> Data {
        try store.exportSession(sessionId)
    }
}
