import Foundation

// Library-agnostic voice-activity gating. The decision logic consumes a stream of
// speech probabilities (0..1) and emits open/close events; it knows nothing about
// the VAD engine that produced the probabilities or the transcription stream it
// gates. Keeping it pure (and here in MaiCore) makes it fully testable with no
// audio, no model, and no network, and lets the probability source be swapped.
//
// Why gate at all: Soniox bills for the FULL open-stream duration, not the audio
// sent, so during silence the only way to stop paying is to end the stream. The
// gate opens on speech onset (reconnect + flush a pre-roll so the first word is not
// clipped) and closes after sustained silence (a hangover long enough not to flap
// on natural pauses).

public struct VadGateConfig: Sendable, Equatable {
    public var onset: Double           // probability at/above which speech starts (open)
    public var offset: Double          // probability below which a frame counts as silence
    public var hangoverSeconds: Double // sustained silence before closing (anti-flap)
    public var frameSeconds: Double    // duration of one VAD frame (e.g. 512/16000 = 0.032)
    public init(onset: Double, offset: Double, hangoverSeconds: Double, frameSeconds: Double) {
        self.onset = onset; self.offset = offset
        self.hangoverSeconds = hangoverSeconds; self.frameSeconds = frameSeconds
    }
}

public enum VadEvent: Sendable, Equatable { case open, close }

// The gate. `feed` one probability per frame; it returns an event only on a state
// transition. Hysteresis (onset > offset) plus the hangover prevent flapping.
public struct VadGate: Sendable {
    public let config: VadGateConfig
    public private(set) var isOpen: Bool
    private var silenceSeconds: Double = 0

    public init(config: VadGateConfig, startOpen: Bool = false) {
        self.config = config
        self.isOpen = startOpen
    }

    public mutating func feed(probability: Double) -> VadEvent? {
        if !isOpen {
            if probability >= config.onset {
                isOpen = true; silenceSeconds = 0
                return .open
            }
            return nil
        } else {
            if probability < config.offset {
                silenceSeconds += config.frameSeconds
                if silenceSeconds >= config.hangoverSeconds {
                    isOpen = false; silenceSeconds = 0
                    return .close
                }
            } else {
                silenceSeconds = 0   // speech (or near-speech) resets the hangover
            }
            return nil
        }
    }

    // Force the gate shut (e.g. on pause); no event is produced.
    public mutating func reset(open: Bool = false) { isOpen = open; silenceSeconds = 0 }
}

// Splits an arbitrary run of samples into fixed-size frames (Silero v5 wants exactly
// 512 samples per frame at 16 kHz). Leftover samples are retained for the next push.
public struct FrameAccumulator: Sendable {
    public let frameSize: Int
    private var buffer: [Float] = []
    public init(frameSize: Int) { self.frameSize = frameSize }

    public mutating func push(_ samples: [Float]) -> [[Float]] {
        buffer.append(contentsOf: samples)
        guard buffer.count >= frameSize else { return [] }
        var frames: [[Float]] = []
        var index = 0
        while buffer.count - index >= frameSize {
            frames.append(Array(buffer[index..<index + frameSize]))
            index += frameSize
        }
        if index > 0 { buffer.removeFirst(index) }
        return frames
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}

// A byte-capped ring of recent PCM so, on speech onset, the audio captured just
// before (and during the reconnect) can be flushed and the first word is not lost.
// The cap is sized to the pre-roll plus a reconnect margin; drain returns the buffer
// in order and clears it.
public struct PrerollRing: Sendable {
    public let maxBytes: Int
    private var chunks: [Data] = []
    private var total = 0
    public init(maxBytes: Int) { self.maxBytes = max(0, maxBytes) }

    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        chunks.append(data); total += data.count
        while total > maxBytes, chunks.count > 1 {
            total -= chunks.removeFirst().count
        }
    }

    public mutating func drain() -> Data {
        var out = Data(capacity: total)
        for c in chunks { out.append(c) }
        chunks.removeAll(keepingCapacity: true); total = 0
        return out
    }

    public mutating func clear() { chunks.removeAll(keepingCapacity: true); total = 0 }
    public var byteCount: Int { total }
}
