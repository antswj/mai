import Foundation
import MaiCore

// The screen-watch wiring for RealEyes: start the low-rate ScreenWatcher, and on
// each settled change read the frame with Gemini, emit the read, and extract the
// participant roster and active-speaker highlight for the naming layer. The roster
// read is best effort; if it fails the transcript still works with fallback names.
extension RealEyes {
    func startWatching() async throws {
        let watcher = ScreenWatcher(config: config) { [weak self] jpeg in
            self?.readSettledFrame(jpeg)
        }
        try await watcher.start()
        self.watcher = watcher
    }

    private func readSettledFrame(_ jpeg: Data) {
        guard let key = secrets.get("GEMINI_API_KEY") else { return }
        let model = config.screenModel
        Task { [weak self] in
            guard let self else { return }
            let gemini = GeminiVision(apiKey: key, model: model)
            do {
                let text = try await gemini.read(imageData: jpeg, mimeType: "image/jpeg",
                                                 prompt: Self.screenReadPrompt)
                let parsed = Self.parseScreenRead(text)
                self.updateNaming(roster: parsed.roster, highlighted: parsed.highlighted)
                if !parsed.content.isEmpty { self.emit(content: parsed.content) }
            } catch {
                // A failed read leaves the last stored screen in place; no card fires.
            }
        }
    }

    static let screenReadPrompt = """
    You are reading a screen for an ambient assistant. In one or two sentences, say
    what is on this screen. If it is a video call grid, also list the visible
    participant names and which single participant is the current active speaker (the
    highlighted tile). Respond as compact JSON only, no prose:
    {"content":"...","participants":["name", "..."],"active_speaker":"name or empty"}
    """

    static func parseScreenRead(_ text: String) -> (content: String, roster: [String], highlighted: String?) {
        guard let obj = firstJSONObject(text) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [], nil)
        }
        let content = (obj["content"] as? String) ?? text
        var roster: [String] = []
        if let arr = obj["participants"] as? [Any] { roster = arr.compactMap { $0 as? String } }
        let active = (obj["active_speaker"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (content, roster, (active?.isEmpty == false) ? active : nil)
    }

    private static func firstJSONObject(_ text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
