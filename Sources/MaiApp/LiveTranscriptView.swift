import SwiftUI
import MaiCore

// The always-on live transcript, Apple Music lyrics style: the newest line is the
// active line (larger and brighter), earlier lines dim and scroll up. Each line is
// labeled with the speaker and shows furigana/pinyin as true ruby (RubyLineView)
// when ruby is enabled, with the English translation as a dimmer line underneath.
struct LiveTranscriptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live transcript").font(.headline)
            Divider()
            if model.liveLines.isEmpty {
                Spacer()
                Text(model.useSimulated
                     ? "Type a line on the left to see it here."
                     : "Listening. Spoken lines will appear here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(model.liveLines.enumerated()), id: \.element.id) { idx, line in
                                TranscriptLineView(line: line,
                                                   active: idx == model.liveLines.count - 1,
                                                   ruby: model.config.ruby)
                                    .id(line.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: model.liveLines.count) {
                        if let last = model.liveLines.last {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 320)
    }
}

struct TranscriptLineView: View {
    let line: LiveTranscriptLine
    let active: Bool
    let ruby: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.speaker)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if ruby, let lang = line.language, lang != .en {
                RubyLineView(units: Readings.units(line.text, language: lang),
                             baseFont: active ? 22 : 17,
                             dim: active ? 0 : 0.45)
            } else {
                Text(line.text)
                    .font(.system(size: active ? 22 : 17, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? .primary : .secondary)
            }
            if let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: active ? 14 : 12))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(line.isFinal ? 1.0 : 0.85)
        .animation(.easeInOut(duration: 0.2), value: active)
    }
}
