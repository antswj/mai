import SwiftUI
import AppKit
import MaiCore

// SwiftUI macOS app, runnable as a SwiftPM executable with Command Line Tools only
// (no Xcode). The init() activation dance is what makes a non-bundled `swift run`
// binary actually show and foreground its window (verified on Swift 6.3 / macOS 26).
@main
struct MaiApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Launched via `open Mai.app`, the working directory is "/", so the relative
        // paths the app reads (.env, config.toml, data/, prompt files) would not
        // resolve. Mai.app is built into the repo root by make-app.sh, so point the
        // working directory there. Runs before AppModel is created.
        Self.useRepoWorkingDirectory()

        // Use NSApplication.shared (not the NSApp global, which is still nil this
        // early in the SwiftUI lifecycle) to create the app and promote it from an
        // accessory so a non-bundled `swift run` binary shows and foregrounds.
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            app.activate()                          // current macOS 14+ API
            app.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    private static func useRepoWorkingDirectory() {
        let fm = FileManager.default
        func hasConfig(_ dir: String) -> Bool {
            fm.fileExists(atPath: dir + "/.env") || fm.fileExists(atPath: dir + "/config.toml")
        }
        if let home = ProcessInfo.processInfo.environment["MAI_HOME"], hasConfig(home) {
            fm.changeCurrentDirectoryPath(home); return
        }
        // Bundled (Mai.app): the bundle sits in the repo root next to .env/config.toml.
        if Bundle.main.bundleIdentifier != nil {
            let bundleDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
            if hasConfig(bundleDir) { fm.changeCurrentDirectoryPath(bundleDir) }
        }
    }

    var body: some Scene {
        WindowGroup("Mai") {
            VStack(spacing: 0) {
                CaptureBarView(model: model)
                Divider()
                HStack(spacing: 0) {
                    if model.useSimulated {
                        SimulatedInputView(model: model)
                        Divider()
                    }
                    LiveTranscriptView(model: model)
                    Divider()
                    CardStreamView(model: model)
                }
            }
            .frame(minWidth: 980, minHeight: 580)
        }
    }
}
