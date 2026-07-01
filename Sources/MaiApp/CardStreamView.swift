import SwiftUI
import AppKit
import MaiCore

// The Face: a scrolling stream of rich cards, newest first. A card appears the
// instant it is triggered as a skeleton and fills in live as each part lands: the
// answer (always in the interface language), a real image (entity cards), a real
// tappable source, and a suggested response (in the spoken language with ruby and a
// translation) when the response toggle is on. A toggle shows or hides suppressed
// cards.
struct CardStreamView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cards").font(.headline)
                Spacer()
                Toggle("Reply", isOn: Binding(get: { model.responseEnabled },
                                              set: { _ in model.toggleResponse() }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Suggest a reply when one is clearly warranted")
                Toggle("Suppressed", isOn: $model.showSuppressed)
                    .toggleStyle(.switch).controlSize(.small)
            }
            Divider()

            // Pinned carousel at the top of the cards area (one card tall), when any.
            if !model.pinnedCards.isEmpty {
                PinnedCarouselView(model: model)
                Divider()
            }

            let flowing = model.flowingCards
            if flowing.isEmpty && model.pinnedCards.isEmpty {
                Spacer()
                Text("No cards yet. Type a line or load a fixture on the left.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(flowing) { card in
                            RichCardRow(card: card, ruby: model.config.ruby) {
                                Button { model.pin(card) } label: { Image(systemName: "pin") }
                                    .buttonStyle(.plain).help("Pin this card").accessibilityLabel("Pin card")
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))   // a new card feels alive, not a jump-cut
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: flowing.map(\.id))
                }
            }
        }
        .padding(12)
        .frame(minWidth: 360)
    }
}

// The pinned-cards carousel: one card at a time, paged by the arrows, the page dots,
// or a horizontal trackpad swipe. Each pinned card has an X to unpin and a note button
// that marks it for the exported meeting notes. Stays compact (capped height) so it
// does not crowd the flowing cards below.
struct PinnedCarouselView: View {
    @ObservedObject var model: AppModel
    @State private var dragX: CGFloat = 0

    var body: some View {
        let count = model.pinnedCards.count
        let index = min(max(0, model.carouselIndex), max(0, count - 1))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("Pinned", systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if count > 1 {
                    Button { model.carouselPrev() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).disabled(index == 0).accessibilityLabel("Previous pinned card")
                    Text("\(index + 1) of \(count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Button { model.carouselNext() } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).disabled(index == count - 1).accessibilityLabel("Next pinned card")
                }
            }
            if count > 0 {
                let card = model.pinnedCards[index]
                ScrollView {
                    RichCardRow(card: card, ruby: model.config.ruby) {
                        Button { model.toggleNoteCard(card) } label: {
                            Image(systemName: model.isNoted(card.id) ? "note.text.badge.plus" : "note.text")
                                .foregroundStyle(model.isNoted(card.id) ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(model.isNoted(card.id) ? "Marked for the meeting notes" : "Add to the meeting notes")
                        .accessibilityLabel(model.isNoted(card.id) ? "Remove from notes" : "Add to notes")
                        Button { model.unpin(card.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Unpin").accessibilityLabel("Unpin card")
                    }
                }
                .frame(maxHeight: 220)   // one card tall, compact
                .offset(x: dragX)
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { dragX = $0.translation.width / 4 }
                        .onEnded { v in
                            if v.translation.width < -40 { model.carouselNext() }
                            else if v.translation.width > 40 { model.carouselPrev() }
                            withAnimation(.easeOut(duration: 0.18)) { dragX = 0 }
                        }
                )
                // Page dots.
                if count > 1 {
                    HStack(spacing: 5) {
                        ForEach(0..<count, id: \.self) { i in
                            Circle().fill(i == index ? Color.primary : Color.secondary.opacity(0.4))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct RichCardRow<Controls: View>: View {
    let card: RichCard
    var ruby: Bool = true
    @ViewBuilder var controls: Controls

    init(card: RichCard, ruby: Bool = true, @ViewBuilder controls: () -> Controls = { EmptyView() }) {
        self.card = card; self.ruby = ruby; self.controls = controls()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TierBadge(tier: card.tier)
                Text(card.headline).font(.system(.body, weight: .semibold))
                Spacer()
                if card.isLoading { ProgressView().controlSize(.small) }
                controls
            }

            // Entity image (real, async). Only entity cards carry one.
            if let urlStr = card.imageURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 160).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    default:
                        RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12))
                            .frame(height: 90).overlay(ProgressView().controlSize(.small))
                    }
                }
            } else if card.isPending(.image) {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12))
                    .frame(height: 90).overlay(ProgressView().controlSize(.small))
            }

            // The answer, in the interface language.
            if let info = card.info, !info.isEmpty {
                Text(info).font(.system(.body)).textSelection(.enabled)
                    .foregroundStyle(card.suppressed ? .secondary : .primary)
                // A model fallback (no source found) is labeled, never dressed up as sourced.
                if card.unverified {
                    Label("Unverified (no source found)", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if card.isPending(.info) || card.isPending(.route) {
                SkeletonLines(count: 2)
            }

            // Suggested response (Part B): spoken-language line with ruby, then the
            // interface-language translation and a short rationale.
            if let r = card.response {
                ResponseBlock(response: r, ruby: ruby)
            } else if card.isPending(.response) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing a reply...").font(.caption).foregroundStyle(.secondary) }
            }

            // Real, tappable sources (grounded search returns several; entity one).
            let shownSources = card.sources.isEmpty ? (card.source.map { [$0] } ?? []) : Array(card.sources.prefix(4))
            if !shownSources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(shownSources.enumerated()), id: \.offset) { _, source in
                        if let url = URL(string: source.url) {
                            Button { NSWorkspace.shared.open(url) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "link").font(.caption2)
                                    Text(source.title).font(.caption).lineLimit(1)
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    if card.searchSuggestionHTML != nil {
                        Text("via Google Search").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            // Primary action (e.g. open a place in Maps).
            if let action = card.action, let urlStr = action.params["url"], let url = URL(string: urlStr) {
                Button(action.label) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }

            HStack(spacing: 10) {
                Text(card.route.rawValue)
                Text(String(format: "score %.2f", card.score))
                if let ms = card.latencyMs { Text("\(ms) ms") }
                if let why = card.note, card.suppressed { Text("suppressed: \(why)").italic() }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(card.suppressed ? Color.gray.opacity(0.08) : Color.gray.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(card.suppressed ? 0.7 : 1)
    }
}

// The suggested-response block: the reply in the spoken language (ruby over kanji /
// hanzi), the interface-language translation, and a short why.
struct ResponseBlock: View {
    let response: RichResponse
    var ruby: Bool

    // Render ruby whenever the reply text is actually CJK, trusting the response's
    // language tag but falling back to detecting the script from the text.
    private var effectiveLanguage: Language {
        response.language != .en ? response.language : ScriptDetect.language(of: response.spoken)
    }
    private var useRuby: Bool { ruby && effectiveLanguage != .en && !response.spoken.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Suggested reply", systemImage: "bubble.left.and.bubble.right")
                .font(.caption).foregroundStyle(.secondary)
            if useRuby {
                RubyLineView(units: Readings.units(response.spoken, language: effectiveLanguage), baseFont: 18)
            } else {
                Text(response.spoken).font(.system(.body, weight: .medium)).textSelection(.enabled)
            }
            if !response.translation.isEmpty {
                Text(response.translation).font(.callout).foregroundStyle(.secondary)
            }
            if let why = response.rationale, !why.isEmpty {
                Text(why).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// A shimmering placeholder for an answer that is still being looked up.
struct SkeletonLines: View {
    var count: Int = 2
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.18))
                    .frame(height: 11)
                    .frame(maxWidth: i == count - 1 ? 180 : .infinity, alignment: .leading)
            }
        }
        .redacted(reason: .placeholder)
    }
}

struct TierBadge: View {
    let tier: Tier
    var color: Color {
        switch tier { case .critical: return .red; case .medium: return .blue; case .noise: return .gray }
    }
    var body: some View {
        Text(tier.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.25))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
