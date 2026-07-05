import SwiftUI
import MaiCore

struct FeedbackButtons: View {
    @ObservedObject var model: AppModel
    let card: RichCard

    var body: some View {
        HStack(spacing: 4) {
            feedback(.useful, "hand.thumbsup")
            feedback(.notUseful, "hand.thumbsdown")
            feedback(.tooSlow, "timer")
            feedback(.wrongContext, "scope")
        }
    }

    private func feedback(_ kind: CardFeedbackKind, _ symbol: String) -> some View {
        let selected = model.feedbackFor(card.id) == kind
        return Button { model.recordFeedback(card, kind) } label: {
            Image(systemName: selected ? "\(symbol).fill" : symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .help(kind.label)
        .accessibilityLabel(kind.label)
    }
}

struct LatencyTelemetryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Latency Telemetry").font(.headline)
                Spacer()
                Button { model.replayTracePicker() } label: {
                    Label(model.traceReplayRunning ? "Replaying" : "Replay Trace", systemImage: "play.rectangle")
                }
                .disabled(model.traceReplayRunning)
                Button { model.exportAnonymizedTrace() } label: {
                    Label("Export Trace", systemImage: "square.and.arrow.down")
                }
                .disabled(model.traceEventCount == 0)
            }

            HStack(spacing: 16) {
                metric("Cards", "\(model.telemetryCards.count)")
                metric("Trace events", "\(model.traceEventCount)")
                metric("Quality threshold", String(format: "%.2f", model.feedbackUsefulThreshold))
                metric("Feedback", "\(model.feedbackSummary.total)")
            }

            if !model.latencyPercentiles.isEmpty {
                PercentileChart(rows: model.latencyPercentiles)
            }

            if !model.feedbackRouteThresholds.isEmpty {
                RouteThresholdsView(rows: model.feedbackRouteThresholds)
            }

            GoldenPacksView(model: model)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.telemetryCards) { row in
                        TelemetryRow(row: row)
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Telemetry")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
        .frame(minWidth: 100, alignment: .leading)
    }
}

private struct TelemetryRow: View {
    let row: CardTelemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.headline).font(.system(.body, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(row.route.rawValue) / \(row.provider)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                time("paint", row.firstPaintMs)
                time("route", row.routeMs)
                time("source", row.sourceLookupMs)
                time("reply", row.responseMs)
                time("final", row.finalFillMs)
                quality
            }
            if let reason = row.suppressionReason {
                Label(reason, systemImage: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(row.suppressed ? Color.gray.opacity(0.08) : Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func time(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value.map { "\($0) ms" } ?? "-")
                .font(.caption.monospacedDigit())
                .foregroundStyle((value ?? 0) > 3000 ? Color.orange : Color.secondary)
        }
    }

    private var quality: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("quality").font(.caption2).foregroundStyle(.tertiary)
            Text(row.qualityScore.map { "\(row.qualityGrade ?? "") \(String(format: "%.2f", $0))" } ?? "-")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct GoldenPacksView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Golden Packs").font(.subheadline.weight(.semibold))
            ForEach(model.goldenTracePacks) { pack in
                HStack(alignment: .top, spacing: 10) {
                    Button { model.replayGoldenPack(pack) } label: {
                        Label(model.goldenPackRunningID == pack.id ? "Running" : pack.name,
                              systemImage: "checklist")
                    }
                    .disabled(model.traceReplayRunning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pack.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text("\(pack.expectations.count) expectations")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if !model.goldenPackResults.isEmpty {
                ForEach(model.goldenPackResults) { result in
                    HStack {
                        Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.passed ? Color.green : Color.red)
                        Text(result.label).font(.caption.weight(.semibold))
                        Spacer()
                        Text(result.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PercentileChart: View {
    let rows: [LatencyPercentileRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latency Percentiles").font(.subheadline.weight(.semibold))
            ForEach(rows) { row in
                PercentileBarRow(row: row, maxValue: maxValue)
            }
        }
    }

    private var maxValue: Int {
        max(rows.map(\.p99).max() ?? 1, 1)
    }
}

private struct PercentileBarRow: View {
    let row: LatencyPercentileRow
    let maxValue: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(row.route.rawValue) / \(row.provider)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("n=\(row.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            bar("p50", row.p50, .green)
            bar("p95", row.p95, .orange)
            bar("p99", row.p99, .red)
        }
        .padding(8)
        .background(Color.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func bar(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.16))
                    Capsule()
                        .fill(color.opacity(0.72))
                        .frame(width: geo.size.width * CGFloat(value) / CGFloat(maxValue))
                }
            }
            .frame(height: 7)
            Text("\(value) ms")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(value > 3000 ? Color.orange : Color.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }
}

private struct RouteThresholdsView: View {
    let rows: [RouteFeedbackThreshold]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality Learning").font(.subheadline.weight(.semibold))
            ForEach(rows) { row in
                HStack {
                    Text(row.route).font(.caption.weight(.semibold))
                    Spacer()
                    Text("threshold \(String(format: "%.2f", row.threshold))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("n=\(row.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct ProviderHealthView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Provider Health").font(.headline)
                Spacer()
                Button { model.refreshProviderHealth() } label: {
                    if model.providerHealthRunning {
                        Label("Checking", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Check Now", systemImage: "checkmark.shield")
                    }
                }
                .disabled(model.providerHealthRunning)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.providerHealth) { result in
                        ProviderHealthRow(result: result)
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Health")
        .onAppear {
            if model.providerHealth.isEmpty { model.refreshProviderHealth() }
        }
    }
}

private struct ProviderHealthRow: View {
    let result: ProviderHealthResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(result.provider, systemImage: symbol)
                    .font(.system(.body, weight: .semibold))
                Spacer()
                Text(result.state.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            Text(result.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let hint = result.billingHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch result.state {
        case .ok, .setOnly: return .green
        case .notSet: return .secondary
        case .quotaLimited, .outOfBalance: return .orange
        case .invalidKey, .error: return .red
        }
    }

    private var symbol: String {
        switch result.state {
        case .ok, .setOnly: return "checkmark.circle"
        case .notSet: return "minus.circle"
        case .quotaLimited, .outOfBalance: return "exclamationmark.triangle"
        case .invalidKey, .error: return "xmark.octagon"
        }
    }
}
