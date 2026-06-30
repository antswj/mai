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

    var visible: [RichCard] {
        model.showSuppressed ? model.richItems : model.richItems.filter { !$0.suppressed }
    }

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
            if visible.isEmpty {
                Spacer()
                Text("No cards yet. Type a line or load a fixture on the left.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visible) { card in
                            RichCardRow(card: card, ruby: model.config.ruby)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 360)
    }
}

struct RichCardRow: View {
    let card: RichCard
    var ruby: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TierBadge(tier: card.tier)
                Text(card.headline).font(.system(.body, weight: .semibold))
                Spacer()
                if card.isLoading { ProgressView().controlSize(.small) }
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
