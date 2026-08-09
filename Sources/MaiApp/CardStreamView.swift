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
                Toggle("Suppressed", isOn: Binding(get: { model.showSuppressed },
                                                   set: { model.setShowSuppressed($0) }))
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
                Text(model.useSimulated
                     ? "No cards yet. Type a line or load a fixture in simulated input."
                     : "No cards yet. Relevant moments will appear here while Mai listens.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(flowing) { card in
                            RichCardRow(card: card, ruby: model.config.ruby,
                                        glassAmount: model.config.liquidGlassAmount) {
                                FeedbackButtons(model: model, card: card)
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
                    RichCardRow(card: card, ruby: model.config.ruby,
                                glassAmount: model.config.liquidGlassAmount) {
                        FeedbackButtons(model: model, card: card)
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
    var glassAmount: Double = 0.72
    @ViewBuilder var controls: Controls

    init(card: RichCard, ruby: Bool = true, glassAmount: Double = 0.72,
         @ViewBuilder controls: () -> Controls = { EmptyView() }) {
        self.card = card; self.ruby = ruby; self.glassAmount = glassAmount; self.controls = controls()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TierBadge(tier: card.tier)
                Text(card.headline).font(.system(.body, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
                            .frame(maxWidth: .infinity)
                            .frame(height: 160)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    default:
                        RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12))
                            .frame(height: 160).overlay(ProgressView().controlSize(.small))
                    }
                }
            } else if card.isPending(.image) {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12))
                    .frame(height: 160).overlay(ProgressView().controlSize(.small))
            }

            // The answer, in the interface language.
            if let info = card.info, !info.isEmpty {
                if card.route == .sessionOperator {
                    SessionRecapView(text: info, compact: false)
                } else {
                    Text(info).font(.system(.body)).textSelection(.enabled)
                        .foregroundStyle(card.suppressed ? .secondary : .primary)
                }
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
                if let rating = card.rating {
                    Text("quality \(rating.grade) \(String(format: "%.2f", rating.score))")
                } else {
                    Text(String(format: "score %.2f", card.score))
                }
                if let ms = card.latencyMs { Text("\(ms) ms") }
                if let why = card.note, card.suppressed { Text("suppressed: \(why)").italic() }
            }
            .font(.caption2).foregroundStyle(.secondary)

            TrustDetailsView(card: card)
        }
        .padding(10)
        .spatialContentTile(in: RoundedRectangle(cornerRadius: 8, style: .continuous),
                            tint: tierColor, suppressed: card.suppressed,
                            glassAmount: glassAmount)
        .opacity(card.suppressed ? 0.7 : 1)
    }

    private var tierColor: Color {
        switch card.tier { case .critical: return .red; case .medium: return .blue; case .noise: return .gray }
    }
}

struct SessionRecapView: View {
    let text: String
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            ForEach(Array(sections.prefix(compact ? 3 : sections.count).enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: section.title))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(section.bullets.prefix(compact ? 2 : section.bullets.count).enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(Color.secondary.opacity(0.55))
                                .frame(width: 3, height: 3)
                                .padding(.top, 7)
                            Text(bullet)
                                .font(compact ? .caption : .callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                if !compact && section.title != sections.last?.title {
                    Divider().opacity(0.18)
                }
            }
        }
    }

    private var sections: [(title: String, bullets: [String])] {
        let blocks = text.components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n").map(String.init)
            guard let title = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let bullets = lines.dropFirst().map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)
            }.filter { !$0.isEmpty }
            return bullets.isEmpty ? nil : (title, bullets)
        }
    }

    private func icon(for title: String) -> String {
        switch title.lowercased() {
        case let t where t.contains("snapshot"): return "doc.text"
        case let t where t.contains("decision"): return "checkmark.seal"
        case let t where t.contains("follow"): return "arrow.triangle.branch"
        case let t where t.contains("question"): return "questionmark.circle"
        case let t where t.contains("link"): return "link"
        case let t where t.contains("replay"): return "play.circle"
        case let t where t.contains("close"): return "paperplane"
        default: return "note.text"
        }
    }
}

struct TrustDetailsView: View {
    let card: RichCard
    @State private var expanded = false

    var body: some View {
        let signals = visibleSignals
        if !signals.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(signals) { signal in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark.seal")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(signal.label).font(.caption2.weight(.semibold))
                                    Text(String(format: "%.0f%%", signal.confidence * 100))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                Text(signal.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if let rating = card.rating {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Quality \(rating.grade) \(String(format: "%.2f", rating.score)): \(rating.reasons.prefix(4).joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            } label: {
                Label("Why", systemImage: "info.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .disclosureGroupStyle(.automatic)
        }
    }

    private var visibleSignals: [TrustSignal] {
        Array(card.trust.prefix(5))
    }
}

// The suggested-response block: the reply in the spoken language (ruby over kanji /
// hanzi), the interface-language translation, and a short why.
struct ResponseBlock: View {
    let response: RichResponse
    var ruby: Bool

    // Ruby whenever the reply text is actually CJK. The tag-first, script-fallback rule
    // lives on RichResponse so this view and the HUD cannot disagree.
    private var effectiveLanguage: Language { response.rubyLanguage }
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
