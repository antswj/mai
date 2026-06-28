import Foundation
import OnnxRuntimeBindings
import MaiCore

// On-device Silero VAD v5 over ONNX Runtime. Fully local: the model is bundled and
// inference never touches the network. Confirmed model I/O (v5.1.2):
//   inputs:  input [1, 512] float, state [2, 1, 128] float, sr [] int64
//   outputs: output [1, 1] float (speech probability), stateN [2, 1, 128] float
// The recurrent state is carried across frames and reset at the start of a stream.
//
// One instance per audio source, fed serially from that source's capture queue, so
// the mutable state is never raced. probability(frame:) throws; the caller decides
// how to degrade (we hold the gate's current state on a transient error).
public final class SileroVAD: @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession
    private let sampleRate: Int64
    public let frameSize: Int
    private var state: [Float]

    private static let stateCount = 2 * 1 * 128

    public init(modelPath: String, sampleRate: Int = 16000) throws {
        self.env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        self.session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        self.sampleRate = Int64(sampleRate)
        self.frameSize = sampleRate <= 8000 ? 256 : 512
        self.state = [Float](repeating: 0, count: Self.stateCount)
    }

    // Locate the bundled model and build a VAD, or nil if the model is missing.
    public static func bundled(sampleRate: Int) -> SileroVAD? {
        guard let url = Bundle.module.url(forResource: "silero_vad", withExtension: "onnx") else {
            FileHandle.standardError.write(Data("Mai: silero_vad.onnx not found in bundle; VAD gating disabled.\n".utf8))
            return nil
        }
        do { return try SileroVAD(modelPath: url.path, sampleRate: sampleRate) }
        catch {
            FileHandle.standardError.write(Data("Mai: failed to load Silero VAD (\(error)); VAD gating disabled.\n".utf8))
            return nil
        }
    }

    public func reset() { state = [Float](repeating: 0, count: Self.stateCount) }

    // Speech probability 0..1 for exactly `frameSize` Float32 samples at 16 kHz.
    public func probability(frame: [Float]) throws -> Float {
        precondition(frame.count == frameSize, "Silero v5 expects \(frameSize) samples per frame")
        let inputData = frame.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        let input = try ORTValue(tensorData: inputData, elementType: .float,
                                 shape: [1, NSNumber(value: frameSize)])
        let stateData = state.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        let stateValue = try ORTValue(tensorData: stateData, elementType: .float, shape: [2, 1, 128])
        var sr = sampleRate
        let srData = NSMutableData(bytes: &sr, length: MemoryLayout<Int64>.size)
        let srValue = try ORTValue(tensorData: srData, elementType: .int64, shape: [])

        let outputs = try session.run(withInputs: ["input": input, "state": stateValue, "sr": srValue],
                                      outputNames: ["output", "stateN"], runOptions: nil)

        if let stateN = outputs["stateN"], let data = try? stateN.tensorData() {
            let next = floats(from: data)
            if next.count == Self.stateCount { state = next }
        }
        guard let output = outputs["output"], let data = try? output.tensorData() else { return 0 }
        return floats(from: data).first ?? 0
    }

    private func floats(from data: NSMutableData) -> [Float] {
        let count = data.length / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.getBytes(buffer.baseAddress!, length: count * MemoryLayout<Float>.size)
            initialized = count
        }
    }
}
