import Foundation

// Loads the committed prompt templates. Prefers the bundled resource (so the
// engine works when packaged), with a source-tree fallback for dev runs.
public enum Prompts {
    public static func load(_ name: String) -> String {
        if let url = Bundle.module.url(forResource: name, withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        // Fallback: read directly from the source tree (useful in some run modes).
        let candidates = [
            "Sources/MaiCore/Prompts/\(name).txt",
            "\(name).txt",
        ]
        for path in candidates {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }
        }
        return ""
    }

    public static var classifier: String { load("classifier") }
    public static var drafter: String { load("drafter") }
}
