import Foundation

// Helpers for pulling a JSON object out of a model response that may be wrapped
// in prose or code fences. Parse failure is never fatal: callers treat a nil/empty
// result as "no triggers" or "no card", never a crash.
enum JSONExtract {
    /// Returns the substring from the first balanced top-level { ... }.
    static func firstObject(in text: String) -> String? {
        var stripped = text
        // Drop ```json ... ``` fences if present.
        if let range = stripped.range(of: "```") {
            stripped = String(stripped[range.upperBound...])
            if stripped.lowercased().hasPrefix("json") { stripped = String(stripped.dropFirst(4)) }
            if let end = stripped.range(of: "```") { stripped = String(stripped[..<end.lowerBound]) }
        }
        guard let start = stripped.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < stripped.endIndex {
            let ch = stripped[idx]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(stripped[start...idx]) }
                }
            }
            idx = stripped.index(after: idx)
        }
        return nil
    }

    static func decodeObject(_ text: String) -> [String: Any]? {
        guard let obj = firstObject(in: text),
              let data = obj.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
