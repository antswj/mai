import SwiftUI
import AppKit
import MaiCore

// Mai is a menu bar agent (the 24/7 anchor) with two faces: Mission mode (a floating
// HUD panel, managed by the AppDelegate) and the full app window (also AppKit-managed
// so opening it flips to a regular app with standard menus and closing it reverts to
// the resting HUD). One AppModel is shared by both faces and the status item, so the
// transcript, cards, and notes are continuous.
@main
struct MaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Settings, reachable with Command-comma (a standard macOS preferences window).
        Settings {
            SettingsView(model: delegate.model)
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
    private var statusItem: NSStatusItem?
    private weak var statusLineMenuItem: NSMenuItem?
    private weak var sessionLineMenuItem: NSMenuItem?
    private weak var missionMenuItem: NSMenuItem?
    private weak var pauseMenuItem: NSMenuItem?
    private weak var sessionMenuItem: NSMenuItem?
    private weak var muteMenuItem: NSMenuItem?
    private weak var notesMenuItem: NSMenuItem?
    private var pausedForSleep = false

    override init() {
        AppDelegate.useRepoWorkingDirectory()   // resolve .env/config/data before the model reads them
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // resting state: a menu bar agent

        hud = MissionHUDController(model: model, onHideRequest: { [weak self] in
            self?.hideMissionMode()
        })
        installStatusItem()

        // Global summon hotkey (user sets it in Settings; no default is shipped).
        GlobalHotKey.shared.onFire = { [weak self] in self?.summon() }
        HotKeyStore.apply()

        // Suspend capture on sleep, resume on wake.
        power = PowerObserver(
            onSleep: { [weak self] in
                guard let self else { return }
                switch self.model.captureState {
                case .starting, .capturing, .simulated:
                    self.pausedForSleep = true
                case .paused, .unavailable:
                    self.pausedForSleep = false
                }
                if self.pausedForSleep { self.model.pause() }
            },
            onWake: { [weak self] in
                guard let self, self.pausedForSleep else { return }
                self.pausedForSleep = false
                self.model.resume()
            })

        // Phase B: a meeting just finished. The complete export bundle is already on
        // disk for a later phase to pick up; nothing is sent anywhere here.
        model.onMeetingFinished = { _ in }

        // Drive the HUD auto show/hide from the pure activity decision.
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickHUD() }
        }

        // Opening Mai.app should always produce a visible affordance. After onboarding
        // the app can still rest as a menu bar agent when the window is closed, but a
        // fresh launch or Finder reopen should not look like "nothing happened".
        openMain()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMain()
        return true
    }

    private func tickHUD() {
        model.autoSessionTick()
        updateStatusMenu()
        guard let hud, !model.appWindowOpen else { hud?.hide(); return }
        // Only decide show vs hide here. The panel is a fixed size that fills itself, so
        // it is never resized per tick (that was the source of the jumping); repin runs
        // only on show and on a display change.
        if model.shouldShowHUD {
            if !hud.isVisible { hud.show() }
        }
        else if hud.isVisible { hud.hide() }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Mai")
            button.image?.isTemplate = true
            button.toolTip = "Mai"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let statusLine = NSMenuItem(title: statusMenuTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        statusLineMenuItem = statusLine
        menu.addItem(statusLine)

        let sessionLine = NSMenuItem(title: model.sessionLabel, action: nil, keyEquivalent: "")
        sessionLine.isEnabled = false
        sessionLineMenuItem = sessionLine
        menu.addItem(sessionLine)

        menu.addItem(.separator())
        addMenuItem("Open Mai", to: menu, action: #selector(statusOpenMain))
        missionMenuItem = addMenuItem("Show Mission Mode", to: menu, action: #selector(statusToggleMissionMode))
        pauseMenuItem = addMenuItem("Pause Capture", to: menu, action: #selector(statusTogglePause))
        sessionMenuItem = addMenuItem("Stop Session", to: menu, action: #selector(statusToggleSession))
        addMenuItem("Start New Session", to: menu, action: #selector(statusStartNewSession))
        muteMenuItem = addMenuItem("Mute Microphone", to: menu, action: #selector(statusToggleMute))
        notesMenuItem = addMenuItem("Start Note-Taking", to: menu, action: #selector(statusToggleNoteTaking))
        menu.addItem(.separator())
        addMenuItem("Quit Mai", to: menu, action: #selector(statusQuit))

        item.menu = menu
        updateStatusMenu()
    }

    @discardableResult
    private func addMenuItem(_ title: String, to menu: NSMenu, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func updateStatusMenu() {
        statusLineMenuItem?.title = statusMenuTitle
        sessionLineMenuItem?.title = model.sessionLabel
        missionMenuItem?.title = hud?.isVisible == true ? "Hide Mission Mode" : "Show Mission Mode"
        pauseMenuItem?.title = model.isPaused ? "Resume Capture" : "Pause Capture"
        sessionMenuItem?.title = model.sessionActive ? "Stop Session" : "Start Session"
        muteMenuItem?.title = model.micMuted ? "Unmute Microphone" : "Mute Microphone"
        notesMenuItem?.title = model.noteTaking ? "Stop Note-Taking" : "Start Note-Taking"
        statusItem?.button?.toolTip = "Mai - \(statusMenuTitle)"
    }

    private var statusMenuTitle: String {
        switch model.captureState {
        case .capturing:
            return "Listening"
        case .paused:
            return "Paused"
        case .simulated:
            return "Simulated input"
        case .starting:
            return "Starting..."
        case .unavailable(let reason):
            return reason.isEmpty ? "Capture unavailable" : "Capture unavailable: \(reason)"
        }
    }

    @objc private func statusOpenMain() {
        openMain()
    }

    @objc private func statusToggleMissionMode() {
        if hud?.isVisible == true {
            hideMissionMode()
        } else {
            summon()
        }
        updateStatusMenu()
    }

    @objc private func statusTogglePause() {
        model.togglePause()
        updateStatusMenu()
    }

    @objc private func statusToggleSession() {
        if model.sessionActive {
            model.stopCurrentSession()
        } else {
            model.startNewSession()
        }
        updateStatusMenu()
    }

    @objc private func statusStartNewSession() {
        model.startNewSession()
        updateStatusMenu()
    }

    @objc private func statusToggleMute() {
        model.toggleMute()
        updateStatusMenu()
    }

    @objc private func statusToggleNoteTaking() {
        model.toggleNoteTaking()
        updateStatusMenu()
    }

    @objc private func statusQuit() {
        NSApplication.shared.terminate(nil)
    }

    func summon() {
        model.summonMission()
        hud?.summon()
        updateStatusMenu()
    }

    func hideMissionMode() {
        model.hideMission()
        hud?.hide()
        updateStatusMenu()
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
        updateStatusMenu()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        model.appWindowOpen = false
        NSApp.setActivationPolicy(.accessory)   // revert to the resting menu bar agent + HUD
        updateStatusMenu()
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
