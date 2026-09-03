import SwiftUI

/// Status bar isolated into its own view so the high-frequency latency
/// estimate re-renders only this bar, not the transcript or the header.
struct StatusBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var latency: LatencyState

    var body: some View {
        HStack(spacing: 16) {
            statusBadge
            translationPill
            translationStatusMessage
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

        if let message = model.errorMessage {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - Translation connection pill + footer copy

    /// Green/yellow/red connection pill, derived from (status × active
    /// engine) by the tested `TranslationPill.map` function.
    private var translationPill: some View {
        let pill = TranslationPill.map(
            status: model.translationStatus,
            activeEngine: model.activeTranslationEngine
        )
        return Label(pill.label, systemImage: "translate")
            .font(.caption)
            .foregroundStyle(Self.toneColor(pill.tone))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Self.toneColor(pill.tone).opacity(0.15)))
    }

    /// Footer copy next to the pill: retry countdown, the latched-fallback
    /// note (with retry + a jump into Settings), and failure/retry affordances.
    @ViewBuilder
    private var translationStatusMessage: some View {
        switch model.translationStatus {
        case let .unavailable(message):
            HStack(spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("Retry") { model.retryTranslation() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case let .retrying(message):
            Text(message).font(.caption).foregroundStyle(.secondary)
        case let .degraded(message):
            HStack(spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { model.retryTranslation() }
                    .buttonStyle(.link)
                    .font(.caption)
                SettingsLink {
                    Text("Settings").font(.caption)
                }
            }
        case .translating:
            Text("Translating…").font(.caption).foregroundStyle(.secondary)
        case .ready, .idle:
            EmptyView()
        }
    }

    private static func toneColor(_ tone: TranslationPill.Tone) -> Color {
        switch tone {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .neutral: .secondary
        }
    }
}
