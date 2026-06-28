import Foundation
import AVFoundation

// Converts an AVAudioPCMBuffer (any sample rate, float or int, mono or stereo) to
// raw signed 16-bit little-endian PCM, mono, at the target rate, in one pass
// (sample-rate conversion plus float-to-int16 plus stereo-to-mono downmix). The
// converter is held as state so the resampler keeps its filter tail across calls.
// AVFoundation only, no ScreenCaptureKit, so the conversion is unit-testable headless.
// Not thread-safe: confine each instance to one capture queue.
public final class PCM16Converter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    public init(sampleRate: Int = 16000) {
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true)!
    }

    /// Convert one input buffer to raw Int16-LE mono bytes at the target rate.
    public func convert(_ input: AVAudioPCMBuffer) -> Data? {
        let inputFormat = input.format
        if converter == nil || lastInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            lastInputFormat = inputFormat
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let inFrames = input.frameLength
        guard inFrames > 0 else { return Data() }
        let outCapacity = AVAudioFrameCount((Double(inFrames) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return nil }

        // The input block is @Sendable but AVAudioConverter invokes it synchronously
        // within convert(...) on this thread, so opt the captures out explicitly.
        nonisolated(unsafe) let inputBuf = input
        nonisolated(unsafe) var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }   // not .endOfStream for live audio
            fed = true
            outStatus.pointee = .haveData
            return inputBuf
        }

        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        switch status {
        case .haveData, .inputRanDry: break   // both are success
        case .endOfStream, .error: return nil
        @unknown default: return nil
        }

        let frames = Int(output.frameLength)
        guard frames > 0, let ch = output.int16ChannelData else { return Data() }
        return Data(bytes: ch[0], count: frames * MemoryLayout<Int16>.size)  // native == little-endian
    }
}
