import Foundation

// The meeting assistant, behind a clean seam so the backend can be swapped with no
// UI change. The current implementation calls the LLM (Anthropic). Other providers
// (for example a local on-device model in a later phase) implement this same
// protocol; nothing else needs to change.
public struct ChatMessage: Sendable, Codable, Equatable, Identifiable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public let id: String
    public let role: Role
    public let text: String
    public init(id: String = UUID().uuidString, role: Role, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

public protocol AssistantProvider: Sendable {
    // Answers within a meeting. The running transcript (with which lines were the
    // user's own) and the prior chat turns are the context. Returns the reply text.
    func reply(to userMessage: String, transcript: [MeetingLine], history: [ChatMessage], screen: String?) async throws -> String
}

// The Claude-backed assistant. Reuses the existing LLMProvider seam, so it inherits
// the configured Anthropic (or Groq) client. A different backend would implement
// AssistantProvider directly instead.
public struct AnthropicAssistant: AssistantProvider {
    private let llm: LLMProvider
    private let model: String
    private let interface: Language
    private let maxTranscriptChars: Int

    public init(llm: LLMProvider, model: String, interface: Language, maxTranscriptChars: Int = 12000) {
        self.llm = llm; self.model = model; self.interface = interface; self.maxTranscriptChars = maxTranscriptChars
    }

    public func reply(to userMessage: String, transcript: [MeetingLine], history: [ChatMessage], screen: String?) async throws -> String {
        let context = AssistantContext.transcriptContext(transcript, maxChars: maxTranscriptChars)
        var convo = ""
        for m in history.suffix(20) {
            convo += (m.role == .user ? "User: " : "Assistant: ") + m.text + "\n"
        }
        let user = """
        Interface language: \(LookupRouter.name(interface))
        Meeting transcript so far (lines marked "You" are the user's own speech):
        \(context.isEmpty ? "(nothing transcribed yet)" : context)

        On screen now:
        \(screen?.isEmpty == false ? screen! : "(nothing)")

        Conversation so far:
        \(convo.isEmpty ? "(this is the first message)" : convo)
        User: \(userMessage)

        Answer as the assistant now.
        """
        return try await llm.complete(system: Prompts.assistant, user: user, model: model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Pure helpers (no network), so they are unit-tested directly.
public enum AssistantContext {
    // Render the transcript for the prompt, condensing the oldest lines when it would
    // exceed the budget while keeping recent detail verbatim.
    public static func transcriptContext(_ lines: [MeetingLine], maxChars: Int) -> String {
        var rendered = lines.map { "\($0.isUser ? "You" : $0.speaker): \($0.text)" }
        if rendered.joined(separator: "\n").count <= maxChars { return rendered.joined(separator: "\n") }
        var dropped = 0
        while rendered.joined(separator: "\n").count > maxChars && rendered.count > 1 {
            rendered.removeFirst(); dropped += 1
        }
        return "[\(dropped) earlier lines condensed to fit context]\n" + rendered.joined(separator: "\n")
    }

    // Detect a "note this down" request and return the item to note (possibly empty,
    // meaning "note the most recent point"); nil if the message is not a note request.
    public static func noteRequest(_ message: String) -> String? {
        let low = message.lowercased()
        let triggers = ["note this down", "note that down", "add to the notes", "add to notes",
                        "take a note", "make a note", "note this", "note that",
                        "メモして", "メモto", "記録して", "记下来", "记一下", "記下來"]
        for t in triggers {
            let isCJK = t.unicodeScalars.contains { $0.value > 0x2000 }
            let hit = isCJK ? message.contains(t) : low.contains(t)
            guard hit else { continue }
            // Item = the text after the trigger (or after a colon), trimmed.
            if let r = (isCJK ? message.range(of: t) : low.range(of: t)) {
                let tail = String(message[r.upperBound...])
                let item = tail.trimmingCharacters(in: CharacterSet(charactersIn: " :：,，-。、\t"))
                return item
            }
            return ""
        }
        return nil
    }
}
