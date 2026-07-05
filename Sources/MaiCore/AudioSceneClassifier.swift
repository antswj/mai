import Foundation

public struct AudioSceneFeatures: Sendable, Equatable {
    public let durationSeconds: Double
    public let rms: Double
    public let peak: Double
    public let zeroCrossingRate: Double
    public let envelopeVariation: Double
    public let crestFactor: Double
}

public enum AudioSceneClassifier {
    // Conservative local music/noise rejection. This catches steady music beds, tones,
    // hum, and fan-like noise that can false-open VAD. It intentionally does NOT claim
    // to separate speech from loud mixed music; that needs a dedicated source-separation
    // model. In that case Mai keeps the audio rather than risking missed speech.
    public static func isLikelyMusicOnly(_ pcm16: Data, sampleRate: Int,
                                         speechThreshold: Double = 0.015) -> Bool {
        guard let f = features(pcm16, sampleRate: sampleRate), f.durationSeconds >= 0.08 else { return false }
        guard f.rms >= speechThreshold else { return false }
        let steadyEnvelope = f.envelopeVariation < 0.09
        let compressedOrTonal = f.crestFactor < 2.4
        let plausibleAudioBand = f.zeroCrossingRate > 0.006 && f.zeroCrossingRate < 0.35
        return steadyEnvelope && compressedOrTonal && plausibleAudioBand
    }

    public static func features(_ pcm16: Data, sampleRate: Int) -> AudioSceneFeatures? {
        let samples = int16Samples(pcm16)
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        var sumSquares = 0.0
        var peak = 0.0
        var crossings = 0
        var lastSign = 0
        for sample in samples {
            let value = Double(sample) / 32768.0
            let absValue = abs(value)
            sumSquares += value * value
            peak = max(peak, absValue)
            let sign = value > 0 ? 1 : (value < 0 ? -1 : 0)
            if sign != 0, lastSign != 0, sign != lastSign { crossings += 1 }
            if sign != 0 { lastSign = sign }
        }
        let rms = sqrt(sumSquares / Double(samples.count))
        let zcr = Double(crossings) / Double(max(1, samples.count - 1))
        let envelope = envelopeRMS(samples, sampleRate: sampleRate)
        let meanEnv = envelope.isEmpty ? 0 : envelope.reduce(0, +) / Double(envelope.count)
        let envStd = meanEnv > 0
            ? sqrt(envelope.reduce(0) { $0 + pow($1 - meanEnv, 2) } / Double(envelope.count))
            : 0
        let variation = meanEnv > 0 ? envStd / meanEnv : 0
        return AudioSceneFeatures(durationSeconds: Double(samples.count) / Double(sampleRate),
                                  rms: rms, peak: peak, zeroCrossingRate: zcr,
                                  envelopeVariation: variation,
                                  crestFactor: rms > 0 ? peak / rms : 0)
    }

    private static func int16Samples(_ data: Data) -> [Int16] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            return (0..<count).map { Int16(littleEndian: p[$0]) }
        }
    }

    private static func envelopeRMS(_ samples: [Int16], sampleRate: Int) -> [Double] {
        let window = max(64, sampleRate / 50) // about 20 ms
        guard samples.count >= window else { return [] }
        var out: [Double] = []
        var i = 0
        while i + window <= samples.count {
            var sumSquares = 0.0
            for s in samples[i..<(i + window)] {
                let value = Double(s) / 32768.0
                sumSquares += value * value
            }
            out.append(sqrt(sumSquares / Double(window)))
            i += window
        }
        return out
    }
}
