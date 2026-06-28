import Foundation

// Who is who. Source split is the primary signal (mic equals the user, system audio
// equals remote participants); diarization separates remote voices into clusters;
// the on-screen participant grid (names plus the active-speaker highlight) binds a
// cluster to a real name. Everything degrades gracefully: if the screen gives no
// name, fall back to the diarization label, and a manual rename always wins.
// Pure value type so the owning actor never races it; fully testable.

public enum SpeakerSource: String, Sendable {
    case user     // microphone
    case remote   // system audio
}

public struct SpeakerRegistry: Sendable {
    public var userName: String
    private var bindings: [String: String] = [:]   // diarization cluster -> name from screen
    private var manual: [String: String] = [:]     // user-entered renames (win over everything)

    public init(userName: String = "You") { self.userName = userName }

    /// Correlate the audio-active remote cluster with the on-screen highlighted name.
    /// Call only when exactly one tile is highlighted; a nil name is ignored. A manual
    /// rename is never overwritten by the screen.
    public mutating func observe(activeCluster: String?, highlightedName: String?) {
        guard let cluster = activeCluster,
              let name = highlightedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }
        if manual[cluster] == nil { bindings[cluster] = name }
    }

    /// Persist a user-entered name for a cluster (sticks for the session).
    public mutating func rename(cluster: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        manual[cluster] = n
    }

    public mutating func renameUser(to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { userName = n }
    }

    /// Display name for a transcript line, with the documented fallback order:
    /// manual rename, then screen binding, then the diarization label, then a generic.
    public func displayName(source: SpeakerSource, cluster: String?) -> String {
        switch source {
        case .user:
            return userName
        case .remote:
            guard let cluster, !cluster.isEmpty else { return "Speaker" }
            if let m = manual[cluster] { return m }
            if let b = bindings[cluster] { return b }
            return "Speaker \(cluster)"
        }
    }

    public func boundName(forCluster cluster: String) -> String? {
        manual[cluster] ?? bindings[cluster]
    }
}
