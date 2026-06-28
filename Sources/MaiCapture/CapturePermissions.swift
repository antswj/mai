import Foundation
import AVFoundation
import ScreenCaptureKit

// Runtime TCC permission checks, gated before any SCStream starts. ScreenCaptureKit
// microphone capture needs BOTH a Microphone grant (AVCaptureDevice) and a Screen
// Recording grant; neither can be assumed from System Settings.
//
// Screen Recording is checked the ScreenCaptureKit-native way (attempt
// SCShareableContent; success means the grant is effective for capture, a throw
// means it is not). This is deliberately NOT CGPreflightScreenCaptureAccess(), which
// is a launch-time snapshot and returns false negatives for ad-hoc-signed apps even
// when the grant is real (verified against Apple forum reports, 2026-06). The first
// such call also triggers the system prompt; the grant takes effect after a relaunch.
public struct CapturePermissionStatus: Sendable, Equatable {
    public let microphoneGranted: Bool
    public let screenRecordingGranted: Bool
    public init(microphoneGranted: Bool, screenRecordingGranted: Bool) {
        self.microphoneGranted = microphoneGranted
        self.screenRecordingGranted = screenRecordingGranted
    }
    public var bothGranted: Bool { microphoneGranted && screenRecordingGranted }
    public var missing: [String] {
        var m: [String] = []
        if !microphoneGranted { m.append("Microphone") }
        if !screenRecordingGranted { m.append("Screen Recording") }
        return m
    }
}

public enum CapturePermissions {
    public static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Request the microphone, prompting only when status is not yet determined.
    public static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false   // denied or restricted: enable it in System Settings
        }
    }

    /// True when ScreenCaptureKit can actually read the screen (the reliable signal).
    /// A success means granted; any throw (notably SCStreamError.userDeclined) means
    /// not granted. Bounded by a timeout because SCShareableContent can hang.
    public static func screenRecordingGranted() async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                return nil   // timeout
            }
            for await result in group {
                group.cancelAll()
                return result ?? false
            }
            return false
        }
    }

    /// Request the microphone first (no relaunch), then check Screen Recording (which
    /// prompts on first use and needs a relaunch to take effect).
    public static func ensure() async -> CapturePermissionStatus {
        let mic = await requestMicrophone()
        let screen = await screenRecordingGranted()
        return CapturePermissionStatus(microphoneGranted: mic, screenRecordingGranted: screen)
    }
}
