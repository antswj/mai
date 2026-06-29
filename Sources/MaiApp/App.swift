import SwiftUI
import AppKit
import MaiCore

// Mai is a menu bar agent (the 24/7 anchor) with two faces: Mission mode (a floating
// HUD panel, managed by the AppDelegate) and the full app window (also AppKit-managed
// so opening it flips to a regular app with standard menus and closing it reverts to
// the resting HUD). One AppModel is shared by both faces and the menu bar, so the
// transcript, cards, and notes are continuous.
@main
struct MaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Mai", systemImage: "sparkles") {
            MenuBarView(model: delegate.model,
                        openApp: { delegate.openMain() },
                        summon: { delegate.summon() })
        }
        .menuBarExtraStyle(.window)

        // Settings, reachable with Command-comma (a standard macOS preferences window).
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

// The menu bar popover: the always-on anchor. Status, a one-click pause, and quick
// access to Mission mode and the full app. Title-style labels.
struct MenuBarView: View {
    @ObservedObject var model: AppModel
    var openApp: () -> Void
    var summon: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LivingGlow(presence: model.isPaused ? .idle : .listening)
                Text(statusLine).font(.headline)
            }
            if model.noteTaking { Label("Note-taking on", systemImage: "record.circle.fill").foregroundStyle(.red) }

            Divider()
            Button(model.isPaused ? "Resume Capture" : "Pause Capture") { model.togglePause() }
            Button("Show Mission Mode") { summon() }
            Button("Open Mai") { openApp() }
            Divider()
            Button(model.noteTaking ? "Stop Note-Taking" : "Start Note-Taking") { model.toggleNoteTaking() }
            Divider()
            Button("Quit Mai") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var statusLine: String {
        switch model.captureState {
        case .capturing: return "Listening"
        case .paused: return "Paused"
        case .simulated: return "Simulated input"
        case .starting: return "Starting\u{2026}"
        case .unavailable: return "Capture unavailable"
        }
    }
}

// Switches between onboarding and the full app reactively, so completing onboarding
// swaps the content in place.
struct RootWindowView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.onboardingComplete {
            FullAppView(model: model)
        } else {
            OnboardingView(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    private var hud: MissionHUDController?
    private var power: PowerObserver?
    private var hudTimer: Timer?
    private var mainWindow: NSWindow?

    override init() {
        AppDelegate.useRepoWorkingDirectory()   // resolve .env/config/data before the model reads them
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // resting state: a menu bar agent

        hud = MissionHUDController(model: model)

        // Global summon hotkey (user sets it in Settings; no default is shipped).
        GlobalHotKey.shared.onFire = { [weak self] in self?.summon() }
        HotKeyStore.apply()

        // Suspend capture on sleep, resume on wake.
        power = PowerObserver(onSleep: { [weak self] in self?.model.pause() },
                              onWake: { [weak self] in self?.model.resume() })

        // Phase B: a meeting just finished. The complete export bundle is already on
        // disk for a later phase to pick up; nothing is sent anywhere here.
        model.onMeetingFinished = { _ in }

        // Drive the HUD auto show/hide from the pure activity decision.
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickHUD() }
        }

        if !model.onboardingComplete { openMain() }   // first run: walk through setup
    }

    private func tickHUD() {
        guard let hud, !model.appWindowOpen else { hud?.hide(); return }
        if model.shouldShowHUD { if !hud.isVisible { hud.show() } }
        else if hud.isVisible { hud.hide() }
    }

    func summon() {
        model.summonMission()
        hud?.summon()
    }

    func openMain() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Mai"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = NSHostingView(rootView: RootWindowView(model: model))
            w.delegate = self
            mainWindow = w
        }
        NSApp.setActivationPolicy(.regular)   // a real app while the window is open: standard menus
        model.appWindowOpen = true
        hud?.hide()
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        model.appWindowOpen = false
        NSApp.setActivationPolicy(.accessory)   // revert to the resting menu bar agent + HUD
    }

    // Launched via `open Mai.app`, the working directory is "/", so relative paths
    // (.env, config.toml, data/, prompt files) would not resolve. Point it at the repo
    // root (next to the bundle, or MAI_HOME) when those files are present.
    static func useRepoWorkingDirectory() {
        let fm = FileManager.default
        func hasConfig(_ dir: String) -> Bool {
            fm.fileExists(atPath: dir + "/.env") || fm.fileExists(atPath: dir + "/config.toml")
        }
        if let home = ProcessInfo.processInfo.environment["MAI_HOME"], hasConfig(home) {
            fm.changeCurrentDirectoryPath(home); return
        }
        if Bundle.main.bundleIdentifier != nil {
            let bundleDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
            if hasConfig(bundleDir) { fm.changeCurrentDirectoryPath(bundleDir) }
        }
    }
}
