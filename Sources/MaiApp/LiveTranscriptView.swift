import SwiftUI
import MaiCore

// The always-on live transcript, Apple Music lyrics style: the newest line is the
// active line (larger and brighter), earlier lines dim and scroll up. Each line is
// labeled with the speaker and shows furigana/pinyin as true ruby (RubyLineView)
// when ruby is enabled, with the English translation as a dimmer line underneath.
struct LiveTranscriptView: View {
    @ObservedObject var model: AppModel
    @State private var renameTarget: LiveTranscriptLine?
    @State private var renameText: String = ""
    @State private var atBottom = true

    // Changes on ANY transcript update (a new line, a streaming partial growing, or a
    // partial finalizing into a final), unlike liveLines.count which stays the same
    // when a partial is replaced by its final. Drives the auto-scroll.
    private var transcriptSignature: String {
        guard let last = model.liveLines.last else { return "0" }
        return "\(model.liveLines.count)|\(last.id)|\(last.text.count)|\(last.translation?.count ?? 0)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live transcript").font(.headline)
                Spacer()
                Toggle("Translate", isOn: Binding(get: { model.translationOn },
                                                  set: { _ in model.toggleTranslation() }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Show each line translated into \(model.config.interfaceLanguage.rawValue.uppercased()) beneath it")
            }
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
                                    .contextMenu {
                                        Button("Rename speaker...") {
                                            renameTarget = line; renameText = line.speaker
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    // Follow the newest line as the transcript comes in (including while a
                    // partial streams), but only while the user is at the bottom, so
                    // scrolling up to read history is not yanked back down.
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        HUDLayout.isAtBottom(contentOffsetY: geo.contentOffset.y, containerHeight: geo.containerSize.height, contentHeight: geo.contentSize.height)
                    } action: { _, now in atBottom = now }
                    .onChange(of: transcriptSignature) {
                        guard atBottom, let last = model.liveLines.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear { if let last = model.liveLines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 320)
        .alert("Rename speaker", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let target = renameTarget { model.renameSpeaker(target, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }
}

struct TranscriptLineView: View {
    let line: LiveTranscriptLine
    let active: Bool
    let ruby: Bool

    // Furigana/pinyin must show whenever the text is actually CJK, even when Soniox
    // leaves the language untagged (nil) or mis-tags a code-switched line. Trust the
    // line's language only when it is ja/zh; otherwise detect the script from the text.
    private var effectiveLanguage: Language {
        if let lang = line.language, lang != .en { return lang }
        return ScriptDetect.language(of: line.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.speaker)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if ruby, effectiveLanguage != .en, !line.text.isEmpty {
                RubyLineView(units: Readings.units(line.text, language: effectiveLanguage),
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
