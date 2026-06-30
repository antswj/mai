import Foundation

// Loads the committed prompt templates. Prefers the bundled resource (so the
// engine works when packaged), with a source-tree fallback for dev runs.
public enum Prompts {
    public static func load(_ name: String) -> String {
        // Resolve via the install locations (Contents/Resources in a shipped app),
        // never via Bundle.module (which fatal-errors off this machine). Source-tree
        // paths cover `swift run` from the repo.
        if let url = MaiResources.url(forResource: name, withExtension: "txt",
                                      bundleNames: ["Mai_MaiCore"],
                                      sourcePaths: ["Sources/MaiCore/Prompts/\(name).txt", "\(name).txt"]),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return ""
    }

    public static var classifier: String { load("classifier") }
    public static var drafter: String { load("drafter") }
    public static var router: String { load("router") }
    public static var explainer: String { load("explainer") }
    public static var responder: String { load("responder") }
    public static var assistant: String { load("assistant") }
    public static var notesWriter: String { load("notes-writer") }
    public static var notesVerify: String { load("notes-verify") }
    public static var notesTitle: String { load("notes-title") }
}
