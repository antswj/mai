import Foundation
import MaiCore

// The screen-watch wiring for RealEyes. Skeleton for now; the ScreenCaptureKit
// capture, dHash change detection, settle timer, and Gemini read are filled in the
// eyes chunk. Isolated here so that change touches one file.
extension RealEyes {
    func startWatching() async throws {
        // Filled in the eyes chunk: start a low-rate SCStream on the chosen display,
        // dHash each frame, on a settled change read it with Gemini and emit(content:),
        // and extract the participant roster + highlight for naming.
    }
}
