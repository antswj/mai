import Foundation

// Captures microphone and system audio separately via ScreenCaptureKit and hands
// each source's PCM to a callback. Real ScreenCaptureKit wiring is added in the
// capture chunk; this declares the shape RealEars depends on.
public final class AudioCapture: @unchecked Sendable {
    public func stop() {}
}
