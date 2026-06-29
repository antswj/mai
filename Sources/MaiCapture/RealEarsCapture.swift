import Foundation
import MaiCore

// The capture wiring for RealEars: start ScreenCaptureKit audio (mic + system),
// stream each source to its own Soniox connection (mic as the user with no
// diarization; system as remote with diarization), and route segmenter updates to
// the engine (finals) and the UI (partials). Isolated here so the SCK change is one file.
extension RealEars {
    func startCapture() async throws {
        guard let key = secrets.get("SONIOX_API_KEY") else { throw CaptureError.missingKey("SONIOX_API_KEY") }
        let cfg = config
        let translationTarget = cfg.sttTranslation ? cfg.interfaceLanguage.rawValue : nil

        let micConfig = SonioxConfig.json(
            apiKey: key, model: cfg.sttModel, sampleRate: cfg.sttSampleRate, channels: 1,
            languageHints: cfg.sttLanguageHints, languageId: cfg.sttLanguageId,
            diarization: false, translationTarget: translationTarget)
        let systemConfig = SonioxConfig.json(
            apiKey: key, model: cfg.sttModel, sampleRate: cfg.sttSampleRate, channels: 1,
            languageHints: cfg.sttLanguageHints, languageId: cfg.sttLanguageId,
            diarization: cfg.sttDiarization, translationTarget: translationTarget)

        let mic = SonioxClient(configJSON: micConfig,
                               onUpdate: { [weak self] up in self?.handle(up, source: .user) })
        let system = SonioxClient(configJSON: systemConfig,
                                  onUpdate: { [weak self] up in self?.handle(up, source: .remote) })
        setClients(mic: mic, system: system)

        // With VAD gating on, each gate connects its socket lazily on speech onset and
        // tears it down on sustained silence (Soniox bills the full open duration). If
        // VAD is off or the model fails to load, fall back to keeping both streams open.
        if cfg.vadEnabled, let micVad = SileroVAD.bundled(sampleRate: cfg.sttSampleRate),
           let systemVad = SileroVAD.bundled(sampleRate: cfg.sttSampleRate) {
            setGates(mic: VadGatedSource(client: mic, vad: micVad, config: cfg, onSent: { [weak self] bytes in self?.noteSent(); self?.recordSentBytes(bytes) }),
                     system: VadGatedSource(client: system, vad: systemVad, config: cfg, onSent: { [weak self] bytes in self?.noteSent(); self?.recordSentBytes(bytes) }))
        } else {
            setGates(mic: nil, system: nil)
            mic.connect()
            system.connect()
        }

        let capture = AudioCapture(sampleRate: cfg.sttSampleRate) { [weak self] source, data in
            switch source {
            case .user: self?.feedMic(data)
            case .remote: self?.feedSystem(data)
            }
        }
        try await capture.start()
        setAudioCapture(capture)
    }

    private func handle(_ update: SonioxSegmenter.Update, source: SpeakerSource) {
        noteTranscript()   // Soniox responded; transcript pipeline is alive
        if !update.live.isEmpty {
            emitPartial(update.live, speakerLabel: update.liveSpeaker, language: update.liveLanguage,
                        source: source, lineId: "live-\(source.rawValue)")
        }
        for segment in update.finals {
            emitFinal(segment, source: source)
        }
    }
}
