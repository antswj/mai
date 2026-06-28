import Foundation
import MaiCore

// Gates one audio source's Soniox stream by on-device voice activity. Soniox bills
// for the full open-stream duration, so this keeps the socket CLOSED during silence
// and opens it on speech onset, flushing a pre-roll ring so the first word is never
// clipped (the ring also absorbs reconnect latency: audio captured before and during
// the reconnect is buffered, then flushed once the socket is up). After a sustained
// silence (the hangover) it ends the stream to stop billing. The hysteresis between
// onset and offset plus the hangover prevent flapping on natural pauses.
//
// Fed serially from the source's capture queue; an internal lock also guards against
// pause/stop racing a late audio callback.
final class VadGatedSource: @unchecked Sendable {
    private let client: SonioxClient
    private let vad: SileroVAD
    private let lock = NSLock()
    private var gate: VadGate
    private var accumulator: FrameAccumulator
    private var preroll: PrerollRing
    private var streaming = false

    init(client: SonioxClient, vad: SileroVAD, config: Config) {
        self.client = client
        self.vad = vad
        let frameSeconds = Double(vad.frameSize) / Double(config.sttSampleRate)
        self.gate = VadGate(config: VadGateConfig(
            onset: config.vadOnset, offset: config.vadOffset,
            hangoverSeconds: config.vadSilenceHangoverSeconds, frameSeconds: frameSeconds))
        self.accumulator = FrameAccumulator(frameSize: vad.frameSize)
        let bytesPerSecond = config.sttSampleRate * 2                 // Int16 mono
        let capSeconds = config.vadPrerollSeconds + 3.0              // pre-roll + reconnect margin
        self.preroll = PrerollRing(maxBytes: Int(capSeconds * Double(bytesPerSecond)))
    }

    // One chunk of raw PCM16 (Int16 LE, mono, at the STT sample rate).
    func feed(_ pcm16: Data) {
        lock.withLock {
            preroll.append(pcm16)
            var justOpened = false
            for frame in accumulator.push(Self.int16ToFloat(pcm16)) {
                let probability: Double
                do { probability = Double(try vad.probability(frame: frame)) }
                catch { probability = gate.isOpen ? 1.0 : 0.0 }      // hold state on a transient error
                switch gate.feed(probability: probability) {
                case .open:
                    streaming = true; justOpened = true
                    client.connect()
                    client.sendAudio(preroll.drain())               // flush pre-roll + reconnect audio
                case .close:
                    streaming = false
                    client.finalize()
                    client.close()                                  // stop billing during silence
                case nil:
                    break
                }
            }
            // Stream live only when already open; the opening chunk was just flushed.
            if streaming && gate.isOpen && !justOpened {
                client.sendAudio(pcm16)
            }
        }
    }

    func stop() {
        lock.withLock {
            streaming = false
            gate.reset(open: false)
            accumulator.reset()
            preroll.clear()
        }
        client.close()
    }

    static func int16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [Float] in
            let p = raw.bindMemory(to: Int16.self)
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count { out[i] = Float(Int16(littleEndian: p[i])) / 32768.0 }
            return out
        }
    }
}
