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
        let generation = nextReadGeneration()
        let appContext = ScreenAppContext.current()
        Task { [weak self] in
            guard let self else { return }
            let gemini = GeminiVision(apiKey: key, model: model)
            do {
                if let usage = self.usage { await usage.recordVision() }
                let text = try await gemini.read(imageData: jpeg, mimeType: "image/jpeg",
                                                 prompt: Self.screenReadPrompt(appContext: appContext))
                guard self.isCurrentReadGeneration(generation) else { return }
                let parsed = Self.parseScreenRead(text)
                self.updateNaming(roster: parsed.roster, highlighted: parsed.highlighted)
                if !parsed.content.isEmpty {
                    self.emit(content: parsed.content, subject: parsed.subject, appContext: appContext)
                }
            } catch {
                // A failed read leaves the last stored screen in place; no card fires.
            }
        }
    }

    public static let screenReadPrompt = """
    You are reading a screen for an ambient assistant. Respond as compact JSON only, no prose:
    {"content":"...","subject":"...","participants":["name","..."],"active_speaker":"name or empty"}

    - "content": in one or two sentences, what is on this screen.
    - "subject": the single most salient thing worth looking up to help the viewer
      understand or act on this screen: the topic, concept, entity, product, technology,
      person, place, code symbol, or chart subject. Keep proper names in their original
      language and script (do not translate them). Empty string if there is nothing
      worth looking up (a blank screen, a generic desktop, a plain video call with no
      shared content). This is NOT a description; it is the lookup target.
    - "participants"/"active_speaker": only for a video call grid (visible names and the
      single highlighted active speaker); empty otherwise.
    - Ignore Mai's own floating HUD, popup, transcript, and cards if they appear in the
      capture. Describe the underlying app or shared screen instead. If only Mai is
      visible, return empty "content" and "subject".
    """

    static func screenReadPrompt(appContext: ScreenAppContext) -> String {
        guard !appContext.isEmpty else { return screenReadPrompt }
        return screenReadPrompt + """

        Local macOS context (use as a hint, not as a fact source): \(appContext.promptLine)
        - If the active app is a browser, code editor, terminal, CRM, calendar, document,
          or chat app, reflect that in "content" when useful.
        - Prefer the actual visible content over the app name if they conflict.
        """
    }

    public static func parseScreenRead(_ text: String) -> (content: String, subject: String?, roster: [String], highlighted: String?) {
        guard let obj = firstJSONObject(text) else {
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return isLikelySelfOverlay(content: content, subject: nil) ? ("", nil, [], nil) : (content, nil, [], nil)
        }
        let content = ((obj["content"] as? String) ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = (obj["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var roster: [String] = []
        if let arr = obj["participants"] as? [Any] { roster = arr.compactMap { $0 as? String } }
        let active = (obj["active_speaker"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLikelySelfOverlay(content: content, subject: subject) {
            return ("", nil, roster, (active?.isEmpty == false) ? active : nil)
        }
        return (content, (subject?.isEmpty == false) ? subject : nil, roster, (active?.isEmpty == false) ? active : nil)
    }

    private static func isLikelySelfOverlay(content: String, subject: String?) -> Bool {
        let haystack = ([content, subject ?? ""]).joined(separator: " ").lowercased()
        guard haystack.contains("mai") else { return false }

        // Do not suppress actual engineering work about Mai's codebase.
        let codeContext = [".swift", "swift code", "xcode", "code editor", "source file", "function", "class ", "struct "]
        if codeContext.contains(where: { haystack.contains($0) }) { return false }

        let surfaceWords = ["overlay", "floating", "popup", "pop-up", "hud", "heads-up", "panel"]
        let ownUIWords = ["live transcript", "cards", "suggested reply", "provider health", "latency telemetry", "listening", "paused"]
        let describesSurface = surfaceWords.contains { haystack.contains($0) }
        let describesOwnUI = ownUIWords.contains { haystack.contains($0) }
        return describesSurface && describesOwnUI
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
