import SwiftUI
import MaiCore

// Ruby rendered natively in SwiftUI: each base unit gets its reading stacked above
// it (furigana over kanji words, pinyin over hanzi), composed with a custom flow
// Layout so it wraps, scales, and dims with the rest of the view (the live
// transcript's active-line emphasis and the prepared-line cards both use it). The
// reading row is reserved on every unit, reading or not, so baselines stay aligned.
// Readings are generated locally (no API), so this is free per line.
struct RubyLineView: View {
    let units: [RubyUnit]
    var baseFont: CGFloat = 17
    var dim: Double = 0          // 0 = full strength, up to ~0.6 for dimmed lines

    var body: some View {
        FlowLayout(spacing: 2, lineSpacing: 4) {
            ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                RubyUnitView(unit: unit, baseFont: baseFont)
            }
        }
        .opacity(1.0 - dim)
    }
}

struct RubyUnitView: View {
    let unit: RubyUnit
    let baseFont: CGFloat
    private var readingFont: CGFloat { max(8, baseFont * 0.55) }

    var body: some View {
        VStack(spacing: 1) {
            // Reserve the reading row height even when there is no reading, so every
            // base character sits on the same baseline across the line.
            Text(unit.reading ?? "\u{00A0}")
                .font(.system(size: readingFont))
                .kerning(0.5)
                .foregroundStyle(.secondary)
                .opacity(unit.reading == nil ? 0 : 1)
                .fixedSize()
            Text(unit.base)
                .font(.system(size: baseFont))
                .fixedSize()
        }
    }
}

// A simple left-to-right flow layout that wraps to the next line at the width limit.
// Used so ruby units flow naturally and wrap at the window edge.
struct FlowLayout: Layout {
    var spacing: CGFloat = 2
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
