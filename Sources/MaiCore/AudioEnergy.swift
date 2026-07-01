import Foundation

// Pure audio-energy helpers for echo suppression. "Is the speaker actually playing?"
// is answered from the raw system-audio RMS at capture time (the physical truth),
// independent of the VAD/transcription state downstream, which is why it is reliable
// exactly when the echo lands. Unit-tested.
public enum AudioEnergy {
    // Root-mean-square amplitude (0...1) of little-endian signed 16-bit mono PCM.
    public static func rms(_ data: Data) -> Float {
        let n = data.count / 2
        guard n > 0 else { return 0 }
        return data.withUnsafeBytes { raw -> Float in
            let p = raw.bindMemory(to: Int16.self)
            var sum = 0.0
            for i in 0..<n {
                let v = Double(Int16(littleEndian: p[i])) / 32768.0
                sum += v * v
            }
            return Float((sum / Double(n)).squareRoot())
        }
    }

    // Whether a PCM buffer is loud enough to count as active audio (speech-level).
    public static func isLoud(_ data: Data, threshold: Float) -> Bool { rms(data) >= threshold }
}
