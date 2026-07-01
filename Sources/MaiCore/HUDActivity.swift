import Foundation

// Pure logic for Mission mode's auto show/hide and its top-right placement, kept out
// of AppKit so it is unit-tested with no window. The panel is a thin shell that
// reflects these decisions.

public struct HUDActivityInput: Sendable, Equatable {
    public var noteTaking: Bool             // a note-taking session is on (active session)
    public var hasActiveCards: Bool         // at least one currently-relevant card
    public var secondsSinceActivity: Double // time since the last speech, partial, or card
    public var idleHideSeconds: Double      // sustained idle before hiding (tens of seconds)
    public var summoned: Bool               // summoned recently (hotkey/menu), within a grace window
    public var pinned: Bool                 // the user pinned the HUD open
    public var appWindowOpen: Bool          // the full app window is open (it takes over)
    public var paused: Bool                 // capture is paused (privacy valve)
    public init(noteTaking: Bool, hasActiveCards: Bool, secondsSinceActivity: Double,
                idleHideSeconds: Double = HUDActivity.defaultIdleHideSeconds,
                summoned: Bool, pinned: Bool, appWindowOpen: Bool, paused: Bool) {
        self.noteTaking = noteTaking; self.hasActiveCards = hasActiveCards
        self.secondsSinceActivity = secondsSinceActivity; self.idleHideSeconds = idleHideSeconds
        self.summoned = summoned; self.pinned = pinned; self.appWindowOpen = appWindowOpen; self.paused = paused
    }
}

public enum HUDActivity {
    // The HUD must ride through the natural pauses of a conversation, so it does NOT
    // hide on the VAD's short per-utterance silence. It stays visible while there is
    // an active session (note-taking), an ongoing conversation (any activity within
    // the idle window), or a current card, and only slides away after a genuinely long
    // idle. The full app window takes over when open; a pinned HUD never auto-hides; a
    // paused Mai shows nothing unless explicitly summoned.
    public static let defaultIdleHideSeconds: Double = 45

    public static func shouldShow(_ i: HUDActivityInput) -> Bool {
        if i.appWindowOpen { return false }
        if i.summoned { return true }
        if i.pinned { return true }
        if i.paused { return false }
        if i.noteTaking { return true }                       // active session: stay put
        if i.hasActiveCards { return true }                   // a card is showing: stay put
        return i.secondsSinceActivity < i.idleHideSeconds     // recent talk: ride the pauses
    }
}

// A rectangle in screen coordinates (an NSScreen.visibleFrame), bottom-left origin.
public struct ScreenRect: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum HUDLayout {
    // The window ORIGIN (bottom-left) to pin a panel of `size` to the top-right of
    // `visibleFrame` with `inset`. macOS is bottom-left origin, so top == maxY.
    public static func topRightOrigin(visibleFrame f: ScreenRect, size: (width: Double, height: Double), inset: Double) -> (x: Double, y: Double) {
        let x = f.x + f.width - size.width - inset
        let y = f.y + f.height - size.height - inset
        return (x, y)
    }

    // The maximum HUD height: from the top inset down to just above the Dock. The
    // visible frame already excludes the Dock and the menu bar, so the usable height is
    // its height minus the top inset and a small bottom gap. The HUD grows up to this
    // and scrolls within it.
    public static func maxHeight(visibleFrameHeight h: Double, inset: Double, bottomGap: Double = 8) -> Double {
        max(120, h - inset - bottomGap)
    }

    // Split the available height into a transcript area (top) and a cards area (bottom):
    // about 60 percent transcript over 40 percent cards when both are shown, and the
    // transcript taking the full height when there are no cards. The Mission HUD uses
    // this for its generous active layout (and a fixed modest transcript at rest).
    public static func split(availableHeight h: Double, hasCards: Bool, transcriptFraction: Double = 0.6)
        -> (transcript: Double, cards: Double) {
        guard hasCards else { return (h, 0) }
        let t = (h * transcriptFraction).rounded()
        return (t, h - t)
    }
}
