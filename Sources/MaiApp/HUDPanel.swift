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

    init(model: AppModel) {
        self.model = model
        hosting = NSHostingView(rootView: AnyView(MissionHUDView(model: model)))
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 260))
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

    // Re-pin to the top-right of the active screen's visibleFrame (excludes menu bar
    // and Dock), recomputed each show so a display change is always honored. Pin math
    // is the unit-tested HUDLayout.topRightOrigin.
    // Idempotent: called on show, on screen change, and by the 1s tick. It only touches
    // the panel when the target frame actually changes, so in steady state it is a true
    // no-op. (The previous version called setFrame(animate:true) every tick, which made
    // the panel visibly jump and kept resetting the transcript ScrollView's position.)
    func repin() {
        let vf = activeScreen().visibleFrame
        // The HUD can grow from the top inset down to just above the Dock (the visible
        // frame already excludes the Dock and menu bar). Publish this max to the view,
        // but only when it changes, to avoid needless re-renders.
        let maxH = CGFloat(HUDLayout.maxHeight(visibleFrameHeight: Double(vf.height), inset: Double(inset)))
        if model?.hudMaxHeight != maxH { model?.hudMaxHeight = maxH }

        let size = hosting.fittingSize
        let w = size.width > 1 ? size.width : 384
        let h = min(maxH, size.height > 1 ? size.height : 260)   // grow up to the max, then scroll
        let cur = panel.frame
        // Keep the current height if the change is sub-threshold (avoids jitter).
        let targetH = abs(h - cur.height) < 8 ? cur.height : h
        let origin = HUDLayout.topRightOrigin(
            visibleFrame: ScreenRect(x: vf.minX, y: vf.minY, width: vf.width, height: vf.height),
            size: (width: Double(w), height: Double(targetH)), inset: Double(inset))
        let target = NSRect(x: origin.x, y: origin.y, width: w, height: targetH)
        // Steady state: if nothing meaningful changed, do not touch the panel at all
        // (this is what stops the per-tick jumping). Only a real change (a card appearing
        // or leaving, a display change) resizes, and that one change is animated.
        if abs(target.origin.x - cur.origin.x) < 1, abs(target.origin.y - cur.origin.y) < 1,
           abs(target.size.width - cur.size.width) < 1, abs(target.size.height - cur.size.height) < 1 {
            return
        }
        panel.setFrame(target, display: true, animate: true)
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
