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

    // Chrome (header + paddings) subtracted from the panel's max height to get the
    // height available to the content areas.
    private let chrome: CGFloat = 72

    var body: some View {
        let cards = visibleCards
        // Available content height, capped at the panel max (down to just above the Dock).
        let content = max(140, model.hudMaxHeight - chrome)
        let split = HUDLayout.split(availableHeight: Double(content), hasCards: !cards.isEmpty)

        return GlassStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if showAsk {
                    ChatView(model: model, compact: true).frame(height: content)
                } else {
                    // Transcript on top (about 60 percent when cards are shown, full
                    // height otherwise); cards below (about 40 percent), each scrolling.
                    transcriptArea.frame(height: CGFloat(split.transcript))
                    if !cards.isEmpty {
                        cardsArea(cards).frame(height: CGFloat(split.cards))
                    }
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

    private var visibleCards: [RichCard] {
        Array(model.richItems.filter { !$0.suppressed }.prefix(8))
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

    // The transcript area: as many recent lines as fit, scrolling within its height,
    // pinned to the newest (the active line emphasized).
    private var transcriptArea: some View {
        let lines = Array(model.liveLines.suffix(40))
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty {
                        Text(model.isPaused ? "Paused" : "Listening\u{2026}")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                            TranscriptLineView(line: line, active: idx == lines.count - 1, ruby: model.config.ruby)
                                .id(line.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.liveLines.count) {
                if let last = lines.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    // The cards area: the recent cards, newest first, scrolling within its height.
    private func cardsArea(_ cards: [RichCard]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cards) { card in MiniCard(card: card, ruby: model.config.ruby) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
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
