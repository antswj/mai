import Foundation
import AVFoundation
import CoreGraphics

// Runtime TCC permission checks, gated before any SCStream starts. ScreenCaptureKit
// microphone capture needs BOTH a Microphone grant (AVCaptureDevice) and a Screen
// Recording grant (CoreGraphics); neither can be assumed from System Settings, so we
// request/verify both at runtime. Verified current on macOS 26 (2026-06):
// AVCaptureDevice.requestAccess(for: .audio), CGPreflightScreenCaptureAccess(),
// CGRequestScreenCaptureAccess(). Mic takes effect immediately; Screen Recording
// requires a relaunch after granting.
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
        default: return false   // denied or restricted: the user must enable it in Settings
        }
    }

    public static func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// Request the microphone first (no relaunch), then ensure Screen Recording,
    /// prompting for it if needed (that grant requires a relaunch to take effect).
    public static func ensure() async -> CapturePermissionStatus {
        let mic = await requestMicrophone()
        var screen = screenRecordingGranted()
        if !screen { _ = requestScreenRecording(); screen = screenRecordingGranted() }
        return CapturePermissionStatus(microphoneGranted: mic, screenRecordingGranted: screen)
    }
}
