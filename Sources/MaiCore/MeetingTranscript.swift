import Foundation

// One finalized transcript line captured during a note-taking session: who spoke,
// whether it was the user themselves, the text, and when. Codable so a finished
// meeting can be exported whole.
public struct MeetingLine: Sendable, Codable, Equatable {
    public let speaker: String
    public let isUser: Bool
    public let text: String
    public let timestamp: Date
    public let language: String?
    public init(speaker: String, isUser: Bool, text: String, timestamp: Date, language: String? = nil) {
        self.speaker = speaker; self.isUser = isUser; self.text = text
        self.timestamp = timestamp; self.language = language
    }
}

// The structured notes a meeting produced, after the verification pass.
public struct MeetingNotes: Sendable, Codable, Equatable {
    public struct Section: Sendable, Codable, Equatable {
        public let heading: String
        public let bullets: [String]
        public init(heading: String, bullets: [String]) { self.heading = heading; self.bullets = bullets }
    }
    public var summary: String
    public var sections: [Section]
    public init(summary: String, sections: [Section]) { self.summary = summary; self.sections = sections }

    public var isEmpty: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        sections.allSatisfy { $0.bullets.isEmpty }
    }
}

// Everything a finished meeting produces, as one clean bundle. Structured so a
// later phase can pick it up from disk; the handoff itself is out of scope here.
public struct MeetingExport: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let startedAt: Date
    public let endedAt: Date
    public let notes: MeetingNotes
    public let notedItems: [String]      // explicit "note this down" items
    public let transcript: [MeetingLine]
    public let docxFileName: String
    public let markdownFileName: String
}

// Renders the raw transcript as a readable Markdown file with speakers and
// timestamps. Pure and deterministic for a fixed clock; the formatter is UTC-free
// wall-clock HH:mm:ss relative to nothing (absolute local time of each line).
public enum MarkdownTranscript {
    public static func render(title: String, lines: [MeetingLine], startedAt: Date, endedAt: Date) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm"

        var out = "# \(title)\n\n"
        out += "_Transcript recorded \(day.string(from: startedAt)), \(lines.count) lines._\n\n"
        for line in lines {
            let who = line.isUser ? "\(line.speaker) (you)" : line.speaker
            out += "**[\(stamp.string(from: line.timestamp))] \(who):** \(line.text)\n\n"
        }
        return out
    }

    public static func write(title: String, lines: [MeetingLine], startedAt: Date, endedAt: Date, to url: URL) throws {
        try render(title: title, lines: lines, startedAt: startedAt, endedAt: endedAt)
            .data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
