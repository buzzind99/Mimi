import SwiftUI

/// Onboarding: explains screen-recording permission + system audio capture,
/// lets the user pick the ASR model (Lite pre-selected, Full opt-in), and
/// runs the download for the chosen model (progress / resume / retry). A
/// manually dropped-in GGUF is picked up automatically by
/// `ModelLocator.resolve(for:)`.
struct OnboardingView: View {
    var model: AppModel
    @State private var downloader: ModelDownloader

    /// The downloader follows the persisted selection: a relaunch straight
    /// into onboarding with e.g. Full selected must download Full, not the
    /// Lite default.
    init(model: AppModel) {
        self.model = model
        _downloader = State(initialValue: ModelDownloader(choice: model.asrModelSettings.selected))
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.teal)

            VStack(spacing: 6) {
                Text("Welcome to Mimi")
                    .font(.title.bold())
                Text("Real-time Japanese audio transcription & translation")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Mimi listens to the audio playing on your Mac so it can transcribe what you hear. "
                        + "To allow this, macOS asks for Screen Recording access the first time you start; "
                        + "Mimi never records your screen or uploads anything. Everything runs locally on your Mac.")
                } icon: {
                    Image(systemName: "display")
                }
                Label {
                    Text("The speech model (\(selectedChoice.approximateSize)) downloads once from Hugging Face and is stored in Application Support.")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .font(.callout)
            .frame(maxWidth: 520, alignment: .leading)

            modelChoiceCards

            modelSection

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await model.refreshModelAvailability() }
        }
        .onChange(of: downloader.state) { _, _ in
            // Advance out of onboarding once the chosen model lands (or a
            // dropped-in GGUF appears while this screen is up).
            Task { await model.refreshModelAvailability() }
        }
        .onChange(of: selectedChoice) { _, choice in
            // A different target is a different download: stop any in-flight
            // download (its session would otherwise keep running against the
            // abandoned downloader) and start fresh on the new choice.
            downloader.cancel()
            downloader = ModelDownloader(choice: choice)
            Task { await model.refreshModelAvailability() }
        }
    }

    private var selectedChoice: ASRModelChoice {
        model.asrModelSettings.selected
    }

    /// Two description cards (Lite pre-selected): picking one chooses *what
    /// to download* and persists the target choice; the `selectedChoice`
    /// change handles resetting the downloader.
    private var modelChoiceCards: some View {
        HStack(spacing: 12) {
            ForEach(ASRModelChoice.allCases) { choice in
                Button {
                    guard choice != selectedChoice else { return }
                    model.asrModelSettings.select(choice)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(choice.displayName).font(.headline)
                            if choice == selectedChoice {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.teal)
                            }
                        }
                        Text("\(choice.approximateSize) · \(choice.blurb)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(12)
                    .frame(maxWidth: 250, alignment: .leading)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(choice == selectedChoice ? Color.teal.opacity(0.12) : Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            choice == selectedChoice ? Color.teal : Color.clear, lineWidth: 1.5
                        )
                )
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        switch downloader.state {
        case .idle, .failed:
            VStack(spacing: 8) {
                if model.modelAvailability[selectedChoice] == nil {
                    Button("Download \(selectedChoice.displayName) speech model") {
                        downloader.start()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if case let .failed(message) = downloader.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 480)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { downloader.start() }
                        .buttonStyle(.link)
                        .font(.caption)
                    Text(
                        "Offline? Download the GGUF on another machine and drop it into "
                            + "~/Library/Application Support/Mimi/models/ — Mimi picks it up automatically."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                } else if model.modelURL == nil {
                    Text("Or drop the GGUF into ~/Library/Application Support/Mimi/models/")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case let .downloading(_, bytes, total):
            VStack(spacing: 6) {
                if let total, total > 0 {
                    ProgressView(value: Double(bytes), total: Double(total))
                    Text(
                        "Downloading \(selectedChoice.displayName) model… "
                            + bytes.formatted(.byteCount(style: .memory)) + " / "
                            + total.formatted(.byteCount(style: .memory))
                    )
                    .font(.caption.monospacedDigit())
                } else {
                    ProgressView()
                    Text(
                        "Downloading \(selectedChoice.displayName) model… "
                            + bytes.formatted(.byteCount(style: .memory))
                    )
                    .font(.caption.monospacedDigit())
                }
                Button("Cancel") { downloader.cancel() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .frame(maxWidth: 420)
        case .done:
            Label("\(selectedChoice.displayName) model ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }

        if let resolved = model.modelURL {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(resolved.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
