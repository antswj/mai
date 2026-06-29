import Foundation

// Pure logic for Mission mode's auto show/hide and its top-right placement, kept out
// of AppKit so it is unit-tested with no window. The panel is a thin shell that
// reflects these decisions.

public struct HUDActivityInput: Sendable, Equatable {
    public var speaking: Bool        // the VAD reports voice activity
    public var hasActiveCards: Bool  // at least one currently-relevant card
    public var summoned: Bool        // the user summoned it recently (hotkey/menu), within a grace window
    public var pinned: Bool          // the user pinned the HUD open
    public var appWindowOpen: Bool   // the full app window is open (it takes over)
    public var paused: Bool          // capture is paused (privacy valve)
    public init(speaking: Bool, hasActiveCards: Bool, summoned: Bool, pinned: Bool, appWindowOpen: Bool, paused: Bool) {
        self.speaking = speaking; self.hasActiveCards = hasActiveCards; self.summoned = summoned
        self.pinned = pinned; self.appWindowOpen = appWindowOpen; self.paused = paused
    }
}

public enum HUDActivity {
    // Mission mode is the resting 24/7 state. It shows when there is something
    // relevant (speech, a card, or an explicit summon) and hides when idle (VAD
    // silence AND no active cards). The full app window takes over when open; a pinned
    // HUD stays; a paused Mai shows nothing unless explicitly summoned.
    public static func shouldShow(_ i: HUDActivityInput) -> Bool {
        if i.appWindowOpen { return false }
        if i.summoned { return true }
        if i.pinned { return true }
        if i.paused { return false }
        return i.speaking || i.hasActiveCards
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
}
