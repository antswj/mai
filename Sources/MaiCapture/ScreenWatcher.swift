import Foundation

// Low-rate ScreenCaptureKit screen watch with a dHash change detector and settle
// timer. Real ScreenCaptureKit wiring is added in the eyes chunk; this declares the
// shape RealEyes depends on.
public final class ScreenWatcher: @unchecked Sendable {
    public func stop() {}
}
