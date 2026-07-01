import AppKit
import SwiftUI
import MaiCore

// The Mission mode floating panel. Verified config (2026-06-29): a non-activating
// borderless NSPanel that floats above everything (including other apps' full-screen
// spaces via .canJoinAllSpaces + .fullScreenAuxiliary), never steals focus (shown
// with orderFrontRegardless), and only takes the keyboard when the ask field is
// clicked (canBecomeKey true, becomesKeyOnlyIfNeeded true). Level .statusBar is the
// confirmed-working level over other apps' full-screen; escalate to .popUpMenu if a
// future macOS needs it (never above .screenSaver, which would cover system alerts).
final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
    }
    // Borderless panels return false by default, which would stop the ask field from
    // ever taking the keyboard; becomesKeyOnlyIfNeeded still gates it to the field.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MissionHUDController {
    let panel: HUDPanel
    private let hosting: NSHostingView<AnyView>
    private let inset: CGFloat = 16
    private weak var model: AppModel?

    // Fixed content width; the height is the full space down to the Dock (computed from
    // the screen). The panel is a FIXED size so it never resizes from moment to moment
    // (no jumping); the SwiftUI content fills it and splits the space internally.
    private let panelWidth: CGFloat = 400

    init(model: AppModel) {
        self.model = model
        hosting = NSHostingView(rootView: AnyView(MissionHUDView(model: model)))
        // Fill the panel: AppKit keeps the content view sized to the panel, and the
        // SwiftUI root uses maxWidth/maxHeight .infinity, so the content always matches
        // the panel size exactly (no clipping, no fitting-size polling).
        hosting.autoresizingMask = [.width, .height]
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 400))
        panel.contentView = hosting
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        repin()
    }

    @objc private func screensChanged() { repin() }
    deinit { NotificationCenter.default.removeObserver(self) }

    // Prefer the screen under the cursor, then the primary; the agent app's key window
    // is unreliable for picking the active display.
    private func activeScreen() -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    // Pin the FIXED-size panel to the top-right of the active screen's visibleFrame
    // (excludes the menu bar and Dock). The panel is a fixed size (width = panelWidth,
    // height = the full space down to the Dock), so this is NOT called on a timer and
    // never resizes moment to moment: it only runs on show and on a display change, and
    // it early-returns when the target frame is unchanged. That is what stops the
    // jumping. The SwiftUI content fills this fixed panel and splits the space itself.
    func repin() {
        let vf = activeScreen().visibleFrame
        let h = CGFloat(HUDLayout.maxHeight(visibleFrameHeight: Double(vf.height), inset: Double(inset)))
        let origin = HUDLayout.topRightOrigin(
            visibleFrame: ScreenRect(x: vf.minX, y: vf.minY, width: vf.width, height: vf.height),
            size: (width: Double(panelWidth), height: Double(h)), inset: Double(inset))
        let target = NSRect(x: origin.x, y: origin.y, width: panelWidth, height: h)
        let cur = panel.frame
        if abs(target.origin.x - cur.origin.x) < 1, abs(target.origin.y - cur.origin.y) < 1,
           abs(target.size.width - cur.size.width) < 1, abs(target.size.height - cur.size.height) < 1 {
            return   // unchanged (same screen): do nothing, so nothing jumps
        }
        panel.setFrame(target, display: true, animate: false)
    }

    var isVisible: Bool { panel.isVisible }
    func show() { repin(); panel.orderFrontRegardless() }   // shows without stealing focus
    func hide() { panel.orderOut(nil) }
    // Summon: bring it up and let the ask field take the keyboard. For a non-activating
    // panel this does not activate the app, so it will not pull the user out of a call.
    func summon() { repin(); panel.makeKeyAndOrderFront(nil) }
}

// Suspend capture on sleep, resume on wake. Must register on NSWorkspace's own
// notification center (verified) or the notifications never arrive.
final class PowerObserver {
    private let onSleep: () -> Void
    private let onWake: () -> Void
    init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onSleep = onSleep; self.onWake = onWake
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(waking), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc private func sleeping() { onSleep() }
    @objc private func waking() { onWake() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
}
