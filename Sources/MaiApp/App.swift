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
