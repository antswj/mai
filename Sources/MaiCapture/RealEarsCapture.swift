import Foundation
import MaiCore

// The capture wiring for RealEars. Skeleton for now (no microphone yet); the
// ScreenCaptureKit audio path and the two Soniox connections are filled in the
// capture chunk. Isolated here so that change touches one file.
extension RealEars {
    func startCapture() async throws {
        // Filled in the capture chunk: start AudioCapture (mic + system), convert to
        // PCM16, stream each to its own SonioxClient, route updates to emitFinal /
        // emitPartial. For now this is a no-op so the wiring compiles and runs.
    }
}
