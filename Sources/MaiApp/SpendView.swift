import SwiftUI
import MaiCore

// The spend and usage meter: a rough estimate of what Mai costs per day across its
// paid services, from local aggregate counts only (never content). Confirms VAD
// gating saves money during silence. Clearly labeled an estimate.
struct SpendView: View {
    @ObservedObject var model: AppModel

    private func dollars(_ v: Double) -> String { String(format: "$%.2f", v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Estimated Spend Today").font(.headline)
                Spacer()
                Button("Refresh") { Task { await model.refreshSpend() } }
            }

            Text(dollars(model.spend.total))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()

            VStack(spacing: 8) {
                row("Transcription", model.spend.transcription, "waveform")
                row("Screen reads", model.spend.vision, "eye")
                row("Model", model.spend.model, "brain")
                row("Web search", model.spend.search, "magnifyingglass")
            }

            Text("This is an estimate from local usage counts, not a bill. Transcription is billed by the audio actually streamed, so voice-activity gating lowers it during silence.")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .navigationTitle("Spend")
        .onAppear { Task { await model.refreshSpend() } }
    }

    private func row(_ label: String, _ amount: Double, _ symbol: String) -> some View {
        HStack {
            Label(label, systemImage: symbol)
            Spacer()
            Text(dollars(amount)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
