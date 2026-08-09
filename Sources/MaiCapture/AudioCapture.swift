import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import MaiCore

public enum CaptureError: Error, CustomStringConvertible, LocalizedError {
    case noDisplay
    case noShareableContent
    case missingKey(String)
    public var description: String {
        switch self {
        case .noDisplay:
            return "ScreenCaptureKit returned no displays. This can happen briefly right after granting permission, so relaunching Mai.app usually fixes it."
        case .noShareableContent: return "could not read shareable content (grant Screen Recording)"
        case .missingKey(let k): return "missing \(k)"
        }
    }
    public var errorDescription: String? { description }
}

public enum CaptureSelfWindowMatcher {
    public static func isSelf(ownerBundleIdentifier: String?, ownerProcessID: pid_t,
                              currentBundleIdentifier: String?, currentProcessID: pid_t) -> Bool {
        if ownerProcessID == currentProcessID { return true }
        guard let ownerBundleIdentifier, let currentBundleIdentifier else { return false }
        return ownerBundleIdentifier == currentBundleIdentifier
    }
}

struct CaptureDisplayFilter {
    let display: SCDisplay
    let excludedWindows: [SCWindow]
    let excludedWindowIDs: Set<CGWindowID>
}

// Reliable shareable-content fetch. Uses excludingDesktopWindows (the battle-tested
// call) rather than SCShareableContent.current, which can return empty displays on
// current macOS, and retries because display enumeration can transiently be empty in
// the moment after Screen Recording is granted. The filter excludes Mai's own windows
// so screen reads see the app underneath the floating HUD instead of reading Mai back
// to itself.
enum CaptureContent {
    static func firstDisplay(retries: Int = 6, delayMs: UInt64 = 300) async throws -> SCDisplay {
        for _ in 0...retries {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
               let display = content.displays.first {
                return display
            }
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
        throw CaptureError.noDisplay
    }

    static func firstDisplayFilterExcludingSelf(retries: Int = 6, delayMs: UInt64 = 300) async throws -> CaptureDisplayFilter {
        for _ in 0...retries {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
               let display = content.displays.first {
                let excluded = selfWindows(in: content.windows)
                return CaptureDisplayFilter(
                    display: display,
                    excludedWindows: excluded,
                    excludedWindowIDs: Set(excluded.map(\.windowID)))
            }
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
        throw CaptureError.noDisplay
    }

    private static func selfWindows(in windows: [SCWindow]) -> [SCWindow] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleID = Bundle.main.bundleIdentifier
        return windows.filter { window in
            guard let app = window.owningApplication else { return false }
            return CaptureSelfWindowMatcher.isSelf(
                ownerBundleIdentifier: app.bundleIdentifier,
                ownerProcessID: app.processID,
                currentBundleIdentifier: currentBundleID,
                currentProcessID: currentPID)
        }
    }
}

// Captures microphone and system audio SEPARATELY via ScreenCaptureKit, excludes
// Mai's own output, converts each source to PCM16 mono at the target rate, and hands
// the bytes to a callback tagged by source (mic = the user, system = remote
// participants). Verified against current ScreenCaptureKit (macOS 15+): separate
// .audio and .microphone outputs on their own queues; format built per buffer.
public final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sampleRate: Int
    private let onPCM: @Sendable (SpeakerSource, Data) -> Void
    private let onStreamError: (@Sendable (String) -> Void)?
    private var stream: SCStream?
    private let systemQueue = DispatchQueue(label: "mai.audio.system", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "mai.audio.mic", qos: .userInitiated)
    private let systemConverter: PCM16Converter
    private let micConverter: PCM16Converter
    private var activity: NSObjectProtocol?

    public init(sampleRate: Int,
                onPCM: @escaping @Sendable (SpeakerSource, Data) -> Void,
                onStreamError: (@Sendable (String) -> Void)? = nil) {
        self.sampleRate = sampleRate
        self.onPCM = onPCM
        self.onStreamError = onStreamError
        self.systemConverter = PCM16Converter(sampleRate: sampleRate)
        self.micConverter = PCM16Converter(sampleRate: sampleRate)
        super.init()
    }

    public func start() async throws {
        // Microphone and Screen Recording grants are requested and verified up front
        // by CapturePermissions before this runs, so the SCStream only starts when
        // both are granted.
        let displayFilter = try await CaptureContent.firstDisplayFilterExcludingSelf()
        // Audio capture requires a valid display filter even though we ignore video.
        let filter = SCContentFilter(display: displayFilter.display, excludingWindows: displayFilter.excludedWindows)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true   // never capture Mai's own output
        config.sampleRate = 48000
        config.channelCount = 2
        // Keep video negligible: tiny, slow, not consumed.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        // Acoustic echo cancellation note (verified 2026-06): macOS AEC is the
        // Voice-Processing IO audio unit, which requires an AVAudioEngine/AudioUnit
        // INPUT pipeline. The microphone here arrives as a ScreenCaptureKit media
        // stream (.microphone output), not an audio-unit input, so voice-processing
        // cannot be hosted on this path cleanly (enabling it reshapes the mic to a
        // 9-channel format and crashes converters on the realtime thread). We do not
        // force it; speaker-to-mic echo is removed by the transcript-level
        // EchoSuppressor backstop instead (and headphones remove it at the source).
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        self.stream = stream

        // Resist App Nap so always-on capture keeps running when unfocused.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Mai continuous capture")

        try await stream.startCapture()
    }

    public func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch outputType {
        case .audio: convertAndEmit(sampleBuffer, source: .remote, converter: systemConverter)
        case .microphone: convertAndEmit(sampleBuffer, source: .user, converter: micConverter)
        case .screen: break
        @unknown default: break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // A stream that stops on its own (display reconfiguration, a revoked grant, an
        // internal ScreenCaptureKit error) delivers no further buffers. Reporting it is
        // what lets the watchdog and the user see the difference between a dead capture
        // stack and a quiet room.
        onStreamError?(error.localizedDescription)
    }

    // MARK: - private

    private func convertAndEmit(_ sb: CMSampleBuffer, source: SpeakerSource, converter: PCM16Converter) {
        guard let fmtDesc = sb.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
        // The no-copy buffer aliases the block buffer, so convert (which copies to
        // Data) inside the closure.
        try? sb.withAudioBufferList { abl, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer) else { return }
            if let data = converter.convert(pcm), !data.isEmpty {
                onPCM(source, data)
            }
        }
    }
}
