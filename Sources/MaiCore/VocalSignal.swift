import Foundation

// A compact, privacy-preserving summary of the actual audio behind an utterance.
// Raw PCM never needs to leave the capture layer for coaching: Mai extracts observable
// vocal features locally, then the AI coach reasons over these numbers plus transcript
// context. These are cues for pacing/energy/hesitation only, never proof of intent.
public struct VocalSignal: Codable, Sendable, Equatable {
    public let source: SpeakerSource
    public let capturedAt: Date
    public let windowSeconds: Double
    public let capturedSeconds: Double
    public let speechSeconds: Double
    public let silenceRatio: Double
    public let meanRMS: Double
    public let peakRMS: Double
    public let energyTrend: Double
    public let meanPitchHz: Double?
    public let pitchStdDevHz: Double?
    public let pitchSampleCount: Int
    public let wordCount: Int
    public let estimatedWordsPerMinute: Double?

    public init(source: SpeakerSource, capturedAt: Date, windowSeconds: Double, capturedSeconds: Double,
                speechSeconds: Double, silenceRatio: Double, meanRMS: Double, peakRMS: Double,
                energyTrend: Double, meanPitchHz: Double?, pitchStdDevHz: Double?,
                pitchSampleCount: Int, wordCount: Int, estimatedWordsPerMinute: Double?) {
        self.source = source
        self.capturedAt = capturedAt
        self.windowSeconds = windowSeconds
        self.capturedSeconds = capturedSeconds
        self.speechSeconds = speechSeconds
        self.silenceRatio = max(0, min(1, silenceRatio))
        self.meanRMS = meanRMS
        self.peakRMS = peakRMS
        self.energyTrend = energyTrend
        self.meanPitchHz = meanPitchHz
        self.pitchStdDevHz = pitchStdDevHz
        self.pitchSampleCount = pitchSampleCount
        self.wordCount = wordCount
        self.estimatedWordsPerMinute = estimatedWordsPerMinute
    }

    public var summary: String {
        var parts = [
            "source=\(source.rawValue)",
            "window=\(Self.fmt(windowSeconds))s",
            "speech=\(Self.fmt(speechSeconds))s",
            "pause_ratio=\(Self.fmt(silenceRatio))",
            "mean_rms=\(Self.fmt(meanRMS))",
            "peak_rms=\(Self.fmt(peakRMS))",
            "energy_trend=\(Self.fmt(energyTrend))"
        ]
        if let meanPitchHz {
            parts.append("mean_pitch=\(Self.fmt(meanPitchHz))Hz")
        }
        if let pitchStdDevHz {
            parts.append("pitch_variability=\(Self.fmt(pitchStdDevHz))Hz")
        }
        if let estimatedWordsPerMinute {
            parts.append("pace=\(Self.fmt(estimatedWordsPerMinute))wpm")
        }
        return parts.joined(separator: ", ")
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

public final class VocalSignalTracker: @unchecked Sendable {
    private struct Frame {
        let endedAt: Date
        let duration: Double
        let rms: Double
        let pitchHz: Double?
    }

    private let source: SpeakerSource
    private let sampleRate: Int
    private let speechRMSThreshold: Double
    private let maxWindowSeconds: Double
    private let lock = NSLock()
    private var frames: [Frame] = []

    public init(source: SpeakerSource, sampleRate: Int, speechRMSThreshold: Double = 0.015,
                maxWindowSeconds: Double = 30) {
        self.source = source
        self.sampleRate = max(1, sampleRate)
        self.speechRMSThreshold = max(0, speechRMSThreshold)
        self.maxWindowSeconds = max(1, maxWindowSeconds)
    }

    public func ingest(_ pcm16: Data, at endedAt: Date = Date()) {
        let sampleCount = pcm16.count / 2
        guard sampleCount > 0 else { return }

        var sumSquares = 0.0
        var peak = 0.0
        var samples: [Float] = []
        samples.reserveCapacity(min(sampleCount, 4096))

        pcm16.withUnsafeBytes { raw in
            var byteIndex = 0
            while byteIndex + 1 < raw.count {
                let lo = UInt16(raw[byteIndex])
                let hi = UInt16(raw[byteIndex + 1]) << 8
                let int = Int16(bitPattern: lo | hi)
                let normalized = Double(int) / 32768.0
                let absValue = abs(normalized)
                sumSquares += normalized * normalized
                peak = max(peak, absValue)
                if samples.count < 4096 { samples.append(Float(normalized)) }
                byteIndex += 2
            }
        }

        let rms = sqrt(sumSquares / Double(sampleCount))
        let duration = Double(sampleCount) / Double(sampleRate)
        let pitch = Self.estimatePitchHz(samples: samples, sampleRate: sampleRate, rms: rms)
        let frame = Frame(endedAt: endedAt, duration: duration, rms: rms, pitchHz: pitch)

        lock.withLock {
            frames.append(frame)
            prune(olderThan: endedAt.addingTimeInterval(-maxWindowSeconds))
        }
    }

    public func snapshot(at now: Date = Date(), windowSeconds: Double = 12, utteranceText: String = "") -> VocalSignal? {
        let window = max(1, min(maxWindowSeconds, windowSeconds))
        let selected = lock.withLock { () -> [Frame] in
            prune(olderThan: now.addingTimeInterval(-maxWindowSeconds))
            return frames.filter { now.timeIntervalSince($0.endedAt) <= window }
        }
        guard !selected.isEmpty else { return nil }

        let captured = selected.reduce(0) { $0 + $1.duration }
        guard captured > 0.05 else { return nil }
        let speech = selected.filter { $0.rms >= speechRMSThreshold }.reduce(0) { $0 + $1.duration }
        let weightedRMS = selected.reduce(0) { $0 + $1.rms * $1.duration } / captured
        let peak = selected.map(\.rms).max() ?? 0
        let midpoint = now.addingTimeInterval(-window / 2)
        let first = Self.weightedRMSAverage(selected.filter { $0.endedAt < midpoint })
        let second = Self.weightedRMSAverage(selected.filter { $0.endedAt >= midpoint })
        let trend = second - first
        let pitches = selected.compactMap(\.pitchHz).filter { $0 >= 50 && $0 <= 500 }
        let meanPitch = pitches.isEmpty ? nil : pitches.reduce(0, +) / Double(pitches.count)
        let pitchStd = meanPitch.map { mean -> Double in
            sqrt(pitches.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(1, pitches.count)))
        }
        let words = Self.wordLikeCount(utteranceText)
        let wpm = (words > 0 && speech > 0.25) ? Double(words) / speech * 60.0 : nil

        return VocalSignal(source: source, capturedAt: now, windowSeconds: window,
                           capturedSeconds: captured, speechSeconds: speech,
                           silenceRatio: max(0, 1 - speech / captured),
                           meanRMS: weightedRMS, peakRMS: peak, energyTrend: trend,
                           meanPitchHz: meanPitch, pitchStdDevHz: pitchStd,
                           pitchSampleCount: pitches.count, wordCount: words,
                           estimatedWordsPerMinute: wpm)
    }

    private func prune(olderThan cutoff: Date) {
        frames.removeAll { $0.endedAt < cutoff }
    }

    private static func weightedRMSAverage(_ frames: [Frame]) -> Double {
        let total = frames.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        return frames.reduce(0) { $0 + $1.rms * $1.duration } / total
    }

    private static func estimatePitchHz(samples: [Float], sampleRate: Int, rms: Double) -> Double? {
        guard rms >= 0.012, samples.count >= 512 else { return nil }
        let count = min(samples.count, 4096)
        let mean = samples.prefix(count).reduce(0, +) / Float(count)
        let centered = samples.prefix(count).map { Double($0 - mean) }
        let minLag = max(1, Int(Double(sampleRate) / 350.0))
        let maxLag = min(count / 2, Int(Double(sampleRate) / 70.0))
        guard maxLag > minLag else { return nil }

        var bestLag = 0
        var bestCorr = 0.0
        for lag in minLag...maxLag {
            var sum = 0.0
            var e0 = 0.0
            var e1 = 0.0
            let limit = count - lag
            for i in 0..<limit {
                let a = centered[i]
                let b = centered[i + lag]
                sum += a * b
                e0 += a * a
                e1 += b * b
            }
            guard e0 > 0, e1 > 0 else { continue }
            let corr = sum / sqrt(e0 * e1)
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }
        guard bestLag > 0, bestCorr >= 0.35 else { return nil }
        return Double(sampleRate) / Double(bestLag)
    }

    private static func wordLikeCount(_ text: String) -> Int {
        let latin = text.split { !$0.isLetter && !$0.isNumber }.filter { !$0.isEmpty }.count
        let cjkScalars = text.unicodeScalars.filter {
            (0x3040...0x30ff).contains($0.value)
            || (0x3400...0x9fff).contains($0.value)
            || (0xf900...0xfaff).contains($0.value)
        }.count
        return max(latin, Int((Double(cjkScalars) / 2.0).rounded(.up)))
    }
}
