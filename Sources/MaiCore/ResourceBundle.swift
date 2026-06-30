import Foundation

// Locates a SwiftPM resource bundle WITHOUT touching `Bundle.module`. The generated
// `Bundle.module` accessor resolves only from the executable's own directory or a
// path hardcoded at build time, and it FATAL-ERRORS when neither matches, so it
// cannot be used in a shipped .app (where make-app.sh places the bundles under
// Contents/Resources) and cannot be guarded against. This searches the real install
// locations and returns nil instead of crashing, so callers degrade gracefully.
public enum MaiResources {
    // Returns the resource bundle for a target (e.g. "Mai_MaiCore"), or nil.
    public static func bundle(_ name: String) -> Bundle? {
        let fileName = name + ".bundle"
        var candidates: [URL] = []
        // Shipped app: Contents/Resources/<name>.bundle
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(fileName)) }
        // swift run / flat layout: next to the executable bundle root.
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(fileName))
        // Next to the executable file itself.
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent(fileName))
        }
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path), let b = Bundle(url: url) { return b }
        }
        return nil
    }

    // Finds a resource file across MaiCore/MaiCapture bundles and a source-tree
    // fallback (for `swift run` from the repo). Never crashes.
    public static func url(forResource resource: String, withExtension ext: String,
                           bundleNames: [String] = ["Mai_MaiCore", "Mai_MaiCapture"],
                           sourcePaths: [String] = []) -> URL? {
        for name in bundleNames {
            if let b = bundle(name), let u = b.url(forResource: resource, withExtension: ext) { return u }
        }
        for path in sourcePaths {
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}
