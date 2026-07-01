import SwiftUI
import MaiCore

// Mission mode: a calm, glassy, hovering heads-up display. Real Liquid Glass surface
// (functional layer), a living glow as Mai's presence, vibrant legible text, and
// need-to-know density. Two discrete heights: compact at rest (header + a modest
// auto-following transcript), and a generous 60/40 transcript-over-cards split when
// cards are present. The transcript auto-follows the newest line (so the current
// conversation is always visible without scrolling) while remaining scrollable for
// history.
struct MissionHUDView: View {
    @ObservedObject var model: AppModel
    @State private var showAsk = false
    // The transcript sticks to the newest line only while the user is at the bottom;
    // if they scroll up to read history, new lines do not yank them back down.
    @State private var atBottom = true

    // Header + paddings, subtracted from the panel max to get the content height.
    private let chrome: CGFloat = 76
    // The compact transcript region shown at rest (no cards): several lines, auto-following.
    private let restingTranscript: CGFloat = 168

    private var presence: LivingGlow.Presence {
        if model.assistantThinking { return .thinking }
        if model.isPaused { return .idle }
        return .listening
    }

    var body: some View {
        let cards = visibleCards
        let hasCards = !cards.isEmpty
        // Two discrete heights (no continuous content measurement, which flapped before):
        // compact at rest, generous 60/40 transcript-over-cards when cards are present.
        let maxContent = max(240, model.hudMaxHeight - chrome)
        let split = HUDLayout.split(availableHeight: Double(maxContent), hasCards: hasCards)
        let transcriptH = hasCards ? CGFloat(split.transcript) : restingTranscript

        return GlassStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if showAsk {
                    ChatView(model: model, compact: true).frame(height: maxContent)
                } else {
                    transcriptArea.frame(height: transcriptH)   // ~60% with cards, modest at rest
                    if hasCards {
                        Divider().opacity(0.25)
                        cardsArea(cards).frame(height: CGFloat(split.cards))   // ~40%
                    }
                }
            }
            .padding(16)
            .frame(width: 384)
            .animation(.easeInOut(duration: 0.28), value: hasCards)
            // Real Liquid Glass on the functional layer: the clear variant is the most
            // text-forward, glassiest surface, and it renders its own light-aware edge
            // and adapts to what is behind it, so there is NO manual border (a drawn
            // stroke is the hard edge glass is meant to avoid). The shadow gives depth.
            .missionGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
        }
        .padding(10)
    }

    // Pinned cards first (they never auto-dismiss), then the flowing ones. The HUD shows
    // pinned cards inline (no swipe carousel; that lives in the full app).
    private var visibleCards: [RichCard] {
        Array((model.pinnedCards + model.flowingCards).prefix(8))
    }

    private var header: some View {
        HStack(spacing: 10) {
            LivingGlow(presence: presence)
            Text(model.isPaused ? "Paused" : "Mai")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            // Quiet icon-only controls (each with an accessibility label) so the header
            // stays glanceable: translate, mute, ask, pause.
            Button { model.toggleTranslation() } label: {
                Image(systemName: model.translationOn ? "character.bubble.fill" : "character.bubble")
                    .foregroundStyle(model.translationOn ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Translate the transcript into \(model.config.interfaceLanguage.rawValue.uppercased())")
            .accessibilityLabel(model.translationOn ? "Turn off translation" : "Translate transcript")
            Button { model.toggleMute() } label: {
                Image(systemName: model.micMuted ? "mic.slash.fill" : "mic")
                    .foregroundStyle(model.micMuted ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(model.micMuted ? "Unmute your microphone" : "Mute your microphone")
            .accessibilityLabel(model.micMuted ? "Unmute microphone" : "Mute microphone")
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

    // The transcript area: the full recent history (bounded by the fixed region height,
    // scrollable for older lines), auto-FOLLOWING the newest line so the current
    // conversation is always visible without scrolling. Single owner of the follow: it
    // scrolls to the newest line only while the user is already at the bottom, so
    // scrolling up to read history is never yanked back down by a new line.
    private var transcriptArea: some View {
        let lines = model.liveLines
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
            // True when the scroll is at (or near) the bottom; drives whether to follow.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40
            } action: { _, nowAtBottom in atBottom = nowAtBottom }
            .onChange(of: model.liveLines.count) {
                guard atBottom, let last = lines.last else { return }   // follow only when at the bottom
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear { if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }

    // The cards area: the recent cards, newest first, scrolling within its height.
    private func cardsArea(_ cards: [RichCard]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(cards) { card in
                    MiniCard(card: card, ruby: model.config.ruby,
                             pinned: model.isPinned(card.id), expanded: model.isExpanded(card.id),
                             onTogglePin: { model.isPinned(card.id) ? model.unpin(card.id) : model.pin(card) },
                             onToggleExpand: { withAnimation(.easeInOut(duration: 0.2)) { model.toggleExpand(card.id) } })
                        // A quiet entrance so a new card feels alive, not a jump-cut.
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.25), value: cards.map(\.id))
        }
    }
}

// A compact card for the HUD. Collapsed: headline, a snippet, and a small image
// thumbnail. Tap (the body or the chevron) to expand to the full info, a larger image,
// the reply, and the sources. Pin and source links stay distinct tap targets.
struct MiniCard: View {
    let card: RichCard
    var ruby: Bool
    var pinned: Bool = false
    var expanded: Bool = false
    var onTogglePin: (() -> Void)?
    var onToggleExpand: (() -> Void)?
    private var hasImage: Bool { (card.imageURL.flatMap(URL.init(string:))) != nil }

    private var tint: Color {
        switch card.tier { case .critical: return .red; case .medium: return .blue; case .noise: return .gray }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // A slim tier accent so a card reads as present and its urgency is glanceable.
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.85)).frame(width: 3)
                .padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(card.headline).font(.headline).foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 2)
                Spacer()
                if onToggleExpand != nil {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let onTogglePin {
                    Button(action: onTogglePin) {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.caption).foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel(pinned ? "Unpin card" : "Pin card")
                }
            }

            // Image: a thumbnail collapsed, a larger image when expanded.
            if let urlStr = card.imageURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: expanded ? 160 : 84)
                            .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12))
                            .frame(height: expanded ? 160 : 84)
                    }
                }
            } else if card.isPending(.image) {
                RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)).frame(height: 84)
                    .overlay(ProgressView().controlSize(.small))
            }

            if let info = card.info, !info.isEmpty {
                Text(info).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? nil : 4)
            } else if card.isLoading {
                ProgressView().controlSize(.small)
            }

            if card.unverified, expanded {
                Label("Unverified", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.secondary)
            }

            if let r = card.response {
                Divider().opacity(0.4)
                if ruby && r.language != .en {
                    RubyLineView(units: Readings.units(r.spoken, language: r.language), baseFont: 16)
                } else {
                    Text(r.spoken).font(.callout.weight(.medium)).foregroundStyle(.primary)
                }
                if !r.translation.isEmpty { Text(r.translation).font(.caption).foregroundStyle(.secondary) }
            }

            // Sources: the primary one collapsed, all of them (tappable) when expanded.
            let sources = card.sources.isEmpty ? (card.source.map { [$0] } ?? []) : card.sources
            if expanded {
                ForEach(Array(sources.prefix(4).enumerated()), id: \.offset) { _, src in
                    if let url = URL(string: src.url) {
                        Button { NSWorkspace.shared.open(url) } label: {
                            HStack(spacing: 4) { Image(systemName: "link").font(.caption2); Text(src.title).font(.caption).lineLimit(1) }
                        }.buttonStyle(.link)
                    }
                }
                if let action = card.action, let urlStr = action.params["url"], let url = URL(string: urlStr) {
                    Button(action.label) { NSWorkspace.shared.open(url) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            } else if let first = sources.first {
                Text(first.title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            }
        }
        .padding(12)
        // Translucent, not opaque, so the Liquid Glass surface reads THROUGH the card
        // (present but not a solid slab), with a faint tier tint and a soft shadow for
        // depth. Content stays content; only the surface below is glass.
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        // Tap the card body (not the buttons) to expand/collapse.
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { onToggleExpand?() }
    }
}
