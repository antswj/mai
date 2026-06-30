import SwiftUI
import MaiCore

// Mission mode: a calm, glassy, hovering heads-up display. Glass surface (functional
// layer), a soft rim light and shadow for depth, a living glow as Mai's presence,
// white legible vibrant text, and need-to-know density: the active transcript line or
// two, the one card that matters now, and an ask affordance. Never a dump.
struct MissionHUDView: View {
    @ObservedObject var model: AppModel
    @State private var showAsk = false

    private var presence: LivingGlow.Presence {
        if model.assistantThinking { return .thinking }
        if model.isPaused { return .idle }
        return .listening
    }

    var body: some View {
        GlassStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if showAsk {
                    ChatView(model: model, compact: true).frame(height: 240)
                } else {
                    transcript
                    if let card = topCard { MiniCard(card: card, ruby: model.config.ruby) }
                }
            }
            .padding(14)
            .frame(width: 364)
            // Real Liquid Glass renders its own light-aware edge and adapts to whatever
            // is behind it (darkens over white, lightens over dark), so there is NO
            // manual stroke/border: a hand-drawn border is exactly the hard edge the
            // glass is meant to avoid. The shadow alone gives the hovering depth.
            .functionalGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
        }
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            LivingGlow(presence: presence)
            Text(model.isPaused ? "Paused" : "Mai")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button { withAnimation(.easeInOut(duration: 0.2)) { showAsk.toggle() } } label: {
                Image(systemName: showAsk ? "xmark" : "text.bubble")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showAsk ? "Close ask" : "Ask Mai")
            Button { model.togglePause() } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPaused ? "Resume" : "Pause")
        }
        .foregroundStyle(.secondary)
    }

    private var transcript: some View {
        let recent = Array(model.liveLines.suffix(2))
        return VStack(alignment: .leading, spacing: 6) {
            if recent.isEmpty {
                Text(model.isPaused ? "Paused" : "Listening\u{2026}")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(recent.enumerated()), id: \.element.id) { idx, line in
                    TranscriptLineView(line: line, active: idx == recent.count - 1, ruby: model.config.ruby)
                }
            }
        }
    }

    private var topCard: RichCard? { model.richItems.first { !$0.suppressed } }
}

// A compact card for the HUD: headline, a few lines of info or the reply, a source.
struct MiniCard: View {
    let card: RichCard
    var ruby: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.headline).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            if let info = card.info, !info.isEmpty {
                Text(info).font(.callout).foregroundStyle(.secondary).lineLimit(4)
            } else if card.isLoading {
                ProgressView().controlSize(.small)
            }
            if let r = card.response {
                Divider().opacity(0.4)
                if ruby && r.language != .en {
                    RubyLineView(units: Readings.units(r.spoken, language: r.language), baseFont: 15)
                } else {
                    Text(r.spoken).font(.callout.weight(.medium)).foregroundStyle(.primary)
                }
                if !r.translation.isEmpty { Text(r.translation).font(.caption).foregroundStyle(.secondary) }
            }
            if let source = card.source { Text(source.title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}
