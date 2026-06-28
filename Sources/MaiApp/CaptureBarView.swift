import SwiftUI
import MaiCore

// The always-visible capture indicator plus the pause valve and the simulated-input
// debug toggle. The indicator color and label reflect the live capture state.
struct CaptureBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(.callout, weight: .medium))
            Spacer()
            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                .controlSize(.small)
            Toggle("Simulated", isOn: Binding(
                get: { model.useSimulated },
                set: { _ in model.toggleSimulated() }))
                .toggleStyle(.switch).controlSize(.small)
                .help("Use typed lines and injected screens instead of real capture")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var color: Color {
        switch model.captureState {
        case .capturing: return .red
        case .paused: return .gray
        case .simulated: return .orange
        case .unavailable: return .yellow
        case .starting: return .blue
        }
    }
    private var label: String {
        switch model.captureState {
        case .capturing: return "Capturing"
        case .paused: return "Paused (nothing captured)"
        case .simulated: return "Simulated input"
        case .unavailable(let why): return "Capture unavailable: \(why)"
        case .starting: return "Starting capture..."
        }
    }
}
