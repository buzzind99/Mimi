import SwiftUI

/// Status bar isolated into its own view so the high-frequency latency
/// estimate re-renders only this bar, not the transcript or the header.
struct StatusBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var latency: LatencyState

    var body: some View {
        HStack(spacing: 16) {
            statusBadge
            Spacer()
            Text("≈ \(latency.seconds.formatted(.number.precision(.fractionLength(1)))) s behind")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.phase {
        case .running:
            Label("Capturing", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.green)
        case .sourceLost:
            Label("Source lost — start capture again", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case .starting:
            if model.isPreparingDictionary {
                Label("Building dictionary…", systemImage: "book")
                    .font(.caption)
            } else {
                Label("Starting…", systemImage: "hourglass")
                    .font(.caption)
            }
        case .stopping:
            Label("Stopping…", systemImage: "hourglass.bottomhalf.filled")
                .font(.caption)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon")
                .font(.caption).foregroundStyle(.red)
        case .needsModel:
            Label("Model needed", systemImage: "arrow.down.circle")
                .font(.caption)
        case .idle:
            Label("Idle", systemImage: "circle")
                .font(.caption).foregroundStyle(.secondary)
        }

        switch model.translationStatus {
        case let .unavailable(message):
            HStack(spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("Retry") { model.retryTranslation() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case .translating:
            Text("Translating…").font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }

        if let message = model.errorMessage {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}
