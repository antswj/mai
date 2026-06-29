import SwiftUI
import MaiCore

// The full Mai app: a clean, HIG-correct macOS window. Liquid Glass lives on the
// chrome (the sidebar and toolbar adopt it automatically on macOS 26); the content
// (transcript, cards, notes) stays content. Opening and closing this window switches
// modes; state is continuous with Mission mode because both share one AppModel.
enum AppSection: String, CaseIterable, Identifiable {
    case live = "Live", chat = "Chat", notes = "Notes", spend = "Spend"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .live: return "waveform"
        case .chat: return "bubble.left.and.bubble.right"
        case .notes: return "note.text"
        case .spend: return "dollarsign.circle"
        }
    }
}

struct FullAppView: View {
    @ObservedObject var model: AppModel
    @State private var section: AppSection = .live

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .navigationTitle("Mai")
        } detail: {
            Group {
                switch section {
                case .live: LiveAndCardsView(model: model)
                case .chat: ChatView(model: model).padding()
                case .notes: NotesView(model: model)
                case .spend: SpendView(model: model)
                }
            }
            .frame(minWidth: 560, minHeight: 480)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(model.noteTaking ? "Stop Note-Taking" : "Start Note-Taking") { model.toggleNoteTaking() }
            }
            ToolbarItem {
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
            }
        }
    }
}

struct LiveAndCardsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HSplitView {
            LiveTranscriptView(model: model).frame(minWidth: 300)
            CardStreamView(model: model).frame(minWidth: 320)
        }
    }
}
