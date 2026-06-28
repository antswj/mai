import SwiftUI
import AppKit
import MaiCore

// The Face: a scrolling stream of cards, newest first. Each shows a colored tier
// badge, title, body (for prepared lines: the floor-language line with parenthetical
// readings, then the translation, then the attribution and suggestion note), a
// tappable action if present, and trigger/score/latency as small secondary detail.
// A toggle shows or hides the quietly-rendered suppressed cards.
struct CardStreamView: View {
    @ObservedObject var model: AppModel

    var visible: [DisplayItem] {
        model.showSuppressed ? model.items : model.items.filter { !$0.suppressed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cards").font(.headline)
                Spacer()
                Toggle("Show suppressed", isOn: $model.showSuppressed)
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
                        ForEach(visible) { item in
                            CardRow(item: item,
                                    floorLanguage: model.config.floorLanguage,
                                    meetingMode: model.config.meetingMode,
                                    ruby: model.config.ruby)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 360)
    }
}

struct CardRow: View {
    let item: DisplayItem
    var floorLanguage: Language = .ja
    var meetingMode: Bool = true
    var ruby: Bool = true
    var card: Card { item.card }

    // Prepared-line cards render the floor line as ruby; everything else is plain.
    private var isPreparedLine: Bool {
        card.trigger == .reference && meetingMode && ruby && floorLanguage != .en
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TierBadge(tier: card.tier)
                Text(card.title).font(.system(.body, weight: .semibold))
                Spacer()
            }
            if isPreparedLine {
                let parts = card.body.components(separatedBy: "\n")
                let floor = parts.first ?? card.body
                let translation = parts.count > 1 ? parts[1] : ""
                let note = parts.count > 2 ? parts[2...].joined(separator: "\n") : ""
                VStack(alignment: .leading, spacing: 4) {
                    RubyLineView(units: Readings.units(floor, language: floorLanguage), baseFont: 18)
                    if !translation.isEmpty {
                        Text(translation).font(.callout).foregroundStyle(.secondary)
                    }
                    if !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(card.body)
                    .font(.system(.body))
                    .textSelection(.enabled)
                    .foregroundStyle(item.suppressed ? .secondary : .primary)
            }
            if let action = card.action, let urlStr = action.params["url"], let url = URL(string: urlStr) {
                Button(action.label) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            HStack(spacing: 10) {
                Text(card.trigger.rawValue)
                Text(String(format: "score %.2f", card.score))
                if let ms = card.latencyMs { Text("\(ms) ms") }
                if item.suppressed, let why = item.why { Text("suppressed: \(why)").italic() }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(item.suppressed ? Color.gray.opacity(0.08) : Color.gray.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(item.suppressed ? 0.7 : 1)
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
