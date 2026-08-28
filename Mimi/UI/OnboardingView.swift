import SwiftUI

/// Lite-variant onboarding: explains microphone permission + process-audio
/// capture, includes the source-app picker, and runs the model download
/// (progress / resume / retry). A manually dropped-in GGUF is picked up
/// automatically by `ModelLocator.resolve()`.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @StateObject private var downloader = ModelDownloader()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.teal)

            VStack(spacing: 6) {
                Text("Welcome to Mimi")
                    .font(.title.bold())
                Text("Real-time Japanese livestream transcription & translation")
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Mimi captures the audio of the app you choose (e.g. your browser) using a Core Audio process tap. macOS will ask for Microphone access — required for process audio capture. Nothing is uploaded; speech recognition and translation run on this Mac.")
                } icon: {
                    Image(systemName: "mic")
                }
                Label {
                    Text("The speech model (\(ModelLocator.modelID), ~450 MB) downloads once from Hugging Face and is stored in Application Support.")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .font(.callout)
            .frame(maxWidth: 520, alignment: .leading)

            modelSection

            ProcessPicker(apps: model.apps, selection: $model.selectedApp)
                .frame(width: 280)

            if let selected = model.selectedApp {
                Text("Audio helpers of “\(selected.name)” are tapped automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.refreshApps()
            model.refreshModelAvailability()
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        switch downloader.state {
        case .idle, .failed:
            VStack(spacing: 8) {
                Button("Download speech model") { downloader.start() }
                    .buttonStyle(.borderedProminent)
                if case .failed(let message) = downloader.state {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(maxWidth: 480)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Offline? Download the GGUF on another machine and drop it into ~/Library/Application Support/Mimi/models/ — Mimi picks it up automatically.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: 480)
                } else if ModelLocator.resolve() == nil {
                    Text("Or drop the GGUF into ~/Library/Application Support/Mimi/models/")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        case .downloading(_, let bytes, let total):
            VStack(spacing: 6) {
                if let total, total > 0 {
                    ProgressView(value: Double(bytes), total: Double(total))
                    Text(String(format: "Downloading model… %.1f / %.1f MB", Double(bytes) / 1_048_576, Double(total) / 1_048_576))
                        .font(.caption.monospacedDigit())
                } else {
                    ProgressView()
                    Text("Downloading model… \(bytes / 1_048_576) MB")
                        .font(.caption.monospacedDigit())
                }
                Button("Cancel") { downloader.cancel() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .frame(maxWidth: 420)
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying model…").font(.caption)
            }
        case .done:
            Label("Model ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }

        if let resolved = ModelLocator.resolve() {
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
