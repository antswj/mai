import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import CoreVideo
import AppKit
import MaiCore

// Watches a display at a low frame rate, detects only meaningful settled changes
// with a cheap dHash, and hands the settled frame (as JPEG) to a callback for a
// vision read. A static screen produces no callback, so always-on watching is cheap.
// Verified against current ScreenCaptureKit (skip non-complete frames; 32BGRA at
// ~1 fps). The single .screen output runs on one queue, so the diff state is unraced.
public final class ScreenWatcher: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let config: Config
    private let onSettledFrame: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "mai.screen.watch", qos: .utility)
    private let ciContext = CIContext(options: nil)
    private var stream: SCStream?
    private var filterRefreshTask: Task<Void, Never>?
    private var excludedWindowIDs: Set<CGWindowID> = []

    private var keyframe: UInt64 = 0
    private var pendingHash: UInt64?
    private var pendingSince: Date = .distantPast
    private var firstReadDone = false

    public init(config: Config, onSettledFrame: @escaping @Sendable (Data) -> Void) {
        self.config = config
        self.onSettledFrame = onSettledFrame
        super.init()
    }

    public func start() async throws {
        let displayFilter = try await CaptureContent.firstDisplayFilterExcludingSelf()
        excludedWindowIDs = displayFilter.excludedWindowIDs
        let filter = SCContentFilter(display: displayFilter.display, excludingWindows: displayFilter.excludedWindows)

        let cfg = SCStreamConfiguration()
        let fps = max(1, Int((1.0 / max(0.2, config.screenFrameIntervalSeconds)).rounded()))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.width = max(2, displayFilter.display.width)
        cfg.height = max(2, displayFilter.display.height)
        cfg.queueDepth = 5
        cfg.showsCursor = false

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
        filterRefreshTask = Task { [weak self] in await self?.refreshSelfWindowExclusionLoop() }
    }

    public func stop() {
        filterRefreshTask?.cancel()
        filterRefreshTask = nil
        stream?.stopCapture { _ in }
        stream = nil
        excludedWindowIDs = []
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        // Skip frames that carry no new pixels (idle/blank/duplicate).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let hash = dHash(pixelBuffer)
        let now = Date()

        if !firstReadDone {
            // Establish the first keyframe and read the initial screen once it settles.
            if pendingHash == hash {
                if now.timeIntervalSince(pendingSince) >= config.screenSettleSeconds {
                    fire(pixelBuffer, hash: hash); firstReadDone = true
                }
            } else {
                pendingHash = hash; pendingSince = now
            }
            return
        }

        if FrameDiff.changed(hash, keyframe, threshold: config.screenChangeThreshold) {
            if pendingHash == hash {
                if now.timeIntervalSince(pendingSince) >= config.screenSettleSeconds {
                    fire(pixelBuffer, hash: hash)
                }
            } else {
                pendingHash = hash; pendingSince = now   // still moving; wait to settle
            }
        } else {
            pendingHash = nil   // settled back to the current keyframe; nothing to read
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {}

    // MARK: - private

    private func fire(_ pixelBuffer: CVPixelBuffer, hash: UInt64) {
        keyframe = hash
        pendingHash = nil
        if let jpeg = jpeg(pixelBuffer) { onSettledFrame(jpeg) }
    }

    private func refreshSelfWindowExclusionLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refreshSelfWindowExclusion()
        }
    }

    private func refreshSelfWindowExclusion() async {
        guard let stream else { return }
        guard let displayFilter = try? await CaptureContent.firstDisplayFilterExcludingSelf() else { return }
        guard displayFilter.excludedWindowIDs != excludedWindowIDs else { return }
        let filter = SCContentFilter(display: displayFilter.display, excludingWindows: displayFilter.excludedWindows)
        do {
            try await stream.updateContentFilter(filter)
            excludedWindowIDs = displayFilter.excludedWindowIDs
        } catch {
            // Keep the current filter; the next refresh will try again.
        }
    }

    private func dHash(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard w > 0, h > 0 else { return 0 }
        let small = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: 9.0 / w, y: 8.0 / h))
        var bytes = [UInt8](repeating: 0, count: 9 * 8)
        bytes.withUnsafeMutableBytes { buf in
            ciContext.render(small, toBitmap: buf.baseAddress!, rowBytes: 9,
                             bounds: CGRect(x: 0, y: 0, width: 9, height: 8),
                             format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        return FrameDiff.dHash9x8(bytes)
    }

    private func jpeg(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let ci = visionImage(from: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    private func visionImage(from pixelBuffer: CVPixelBuffer) -> CIImage {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let longEdge = max(ci.extent.width, ci.extent.height)
        let maxLongEdge: CGFloat = 1920
        guard longEdge > maxLongEdge else { return ci }
        let scale = maxLongEdge / longEdge
        return ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
