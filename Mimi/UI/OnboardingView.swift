import SwiftUI

/// Onboarding: explains screen-recording permission + system
/// audio capture, and runs the model download
/// (progress / resume / retry). A manually dropped-in GGUF is picked up
/// automatically by `ModelLocator.resolve()`.
struct OnboardingView: View {
    var model: AppModel
    @State private var downloader = ModelDownloader()

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
                    Text("The speech model (~1 GB) downloads once from Hugging Face and is stored in Application Support.")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .font(.callout)
            .frame(maxWidth: 520, alignment: .leading)

            modelSection

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await model.refreshModelAvailability() }
        }
        .onChange(of: downloader.state) { _, _ in
            // Advance out of onboarding once the model lands (or a dropped-in
            // GGUF appears while this screen is up).
            Task { await model.refreshModelAvailability() }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        switch downloader.state {
        case .idle, .failed:
            VStack(spacing: 8) {
                Button("Download speech model") { downloader.start() }
                    .buttonStyle(.borderedProminent)
                if case let .failed(message) = downloader.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 480)
                        .fixedSize(horizontal: false, vertical: true)
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
                        "Downloading model… \(bytes.formatted(.byteCount(style: .memory))) / "
                            + total.formatted(.byteCount(style: .memory))
                    )
                    .font(.caption.monospacedDigit())
                } else {
                    ProgressView()
                    Text("Downloading model… \(bytes.formatted(.byteCount(style: .memory)))")
                        .font(.caption.monospacedDigit())
                }
                Button("Cancel") { downloader.cancel() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .frame(maxWidth: 420)
        case .done:
            Label("Model ready", systemImage: "checkmark.circle.fill")
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
