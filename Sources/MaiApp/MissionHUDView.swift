import SwiftUI
import MaiCore

// Report the natural content height of each HUD region so it can be sized to its
// content (compact) and only scroll when it overflows.
private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct CardsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

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
    // Measured natural heights of the transcript and cards content, so each region can
    // be sized to its content (compact) and only scroll when it overflows.
    @State private var transcriptNatural: CGFloat = 0
    @State private var cardsNatural: CGFloat = 0

    var body: some View {
        let cards = visibleCards
        // Available content height, capped at the panel max (down to just above the Dock).
        let maxContent = max(140, model.hudMaxHeight - chrome)
        // Content-driven: each region is its natural height, capped so the HUD never
        // exceeds the max and the cards never crowd out the transcript. Compact when
        // short, grows with content, ~60/40 only once both overflow.
        let h = HUDLayout.regionHeights(transcriptNatural: Double(transcriptNatural),
                                        cardsNatural: Double(cardsNatural),
                                        maxContent: Double(maxContent), hasCards: !cards.isEmpty)

        return GlassStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if showAsk {
                    ChatView(model: model, compact: true).frame(height: maxContent)
                } else {
                    transcriptArea.frame(height: max(28, CGFloat(h.transcript)))
                    if !cards.isEmpty {
                        cardsArea(cards).frame(height: CGFloat(h.cards))
                    }
                }
            }
            .padding(14)
            .frame(width: 364)
            .animation(.easeInOut(duration: 0.22), value: h.transcript)
            .animation(.easeInOut(duration: 0.22), value: h.cards)
            // Real Liquid Glass renders its own light-aware edge and adapts to whatever
            // is behind it (darkens over white, lightens over dark), so there is NO
            // manual stroke/border: a hand-drawn border is exactly the hard edge the
            // glass is meant to avoid. The shadow alone gives the hovering depth.
            .functionalGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
        }
        .padding(10)
    }

    // Pinned cards first (they never auto-dismiss), then the flowing ones. The HUD shows
    // pinned cards inline (no swipe carousel; that lives in the full app).
    private var visibleCards: [RichCard] {
        Array((model.pinnedCards + model.flowingCards).prefix(8))
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
                .background(GeometryReader { g in   // measure NATURAL content height for sizing
                    Color.clear.preference(key: TranscriptHeightKey.self, value: g.size.height)
                })
            }
            .onChange(of: model.liveLines.count) {
                if let last = lines.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onPreferenceChange(TranscriptHeightKey.self) { transcriptNatural = $0 }
        }
    }

    // The cards area: the recent cards, newest first, scrolling within its height.
    private func cardsArea(_ cards: [RichCard]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cards) { card in
                    MiniCard(card: card, ruby: model.config.ruby, pinned: model.isPinned(card.id)) {
                        model.isPinned(card.id) ? model.unpin(card.id) : model.pin(card)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.preference(key: CardsHeightKey.self, value: g.size.height)
            })
        }
        .onPreferenceChange(CardsHeightKey.self) { cardsNatural = $0 }
    }
}

// A compact card for the HUD: headline, a few lines of info or the reply, a source.
struct MiniCard: View {
    let card: RichCard
    var ruby: Bool
    var pinned: Bool = false
    var onTogglePin: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(card.headline).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                if let onTogglePin {
                    Button(action: onTogglePin) {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.caption2).foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel(pinned ? "Unpin card" : "Pin card")
                }
            }
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
