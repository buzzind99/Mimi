import SwiftUI

/// Onboarding: explains screen-recording permission + system audio capture,
/// lets the user pick the ASR model (Lite pre-selected, Full opt-in), and
/// runs the download for the chosen model (progress / resume / retry). A
/// manually dropped-in GGUF is picked up automatically by
/// `ModelLocator.resolve(for:)`.
struct OnboardingView: View {
    /// Corner radius shared with the settings cards.
    private let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

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
            brandMark

            VStack(spacing: 6) {
                Text("Welcome to Mimi")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Real-time Japanese audio transcription & translation")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }

            permissionCard

            modelChoiceCards

            modelSection

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
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

    /// Brand mark matching the sidebar header: gradient circle with the 耳
    /// glyph, scaled up for the welcome screen.
    private var brandMark: some View {
        ZStack {
            Circle().fill(Theme.Gradients.brand)
            Text("耳")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 56, height: 56)
    }

    /// Screen-recording + model-download explainer rows inside a themed card.
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Mimi listens to the audio playing on your Mac so it can transcribe what you hear. "
                    + "To allow this, macOS asks for Screen Recording access the first time you start; "
                    + "Mimi never records your screen or uploads anything. Everything runs locally on your Mac.")
            } icon: {
                Image(systemName: "display")
                    .foregroundStyle(Theme.accentPink)
            }
            Label {
                Text("The speech model (\(selectedChoice.approximateSize)) downloads once from Hugging Face and is stored in Application Support.")
            } icon: {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.accentPink)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .cardSurface()
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
                let isSelected = choice == selectedChoice
                Button {
                    guard !isSelected else { return }
                    model.asrModelSettings.select(choice)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(choice.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.primaryText)
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.accentPink)
                            }
                        }
                        Text("\(choice.approximateSize) · \(choice.blurb)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(12)
                    .frame(maxWidth: 250, alignment: .leading)
                }
                .buttonStyle(.plain)
                .hoverHighlight(
                    cardShape, isEnabled: true,
                    tint: Theme.accentPink, opacity: isSelected ? 0.08 : 0.05
                )
                .cardSurface(
                    fill: isSelected ? Theme.accentPink.opacity(0.1) : Theme.cardFill,
                    stroke: isSelected ? Theme.accentPink : Theme.cardStroke
                )
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        switch downloader.state {
        case .idle, .failed:
            VStack(spacing: 10) {
                if model.modelAvailability[selectedChoice] == nil {
                    downloadButton
                }
                if case let .failed(message) = downloader.state {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.toastRedIcon)
                        .frame(maxWidth: 480)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { downloader.start() }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accentPink)
                        .buttonStyle(.plain)
                    Text(
                        "Offline? Download the GGUF on another machine and drop it into "
                            + "~/Library/Application Support/Mimi/models/ — Mimi picks it up automatically."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.gutterText)
                    .frame(maxWidth: 480)
                    .multilineTextAlignment(.center)
                }
            }
        case let .downloading(_, bytes, total):
            VStack(spacing: 8) {
                ModelDownloadProgressView(
                    bytes: bytes, total: total,
                    tint: Theme.accentPink,
                    font: .system(size: 11).monospacedDigit(),
                    textColor: Theme.secondaryText,
                    alignment: .center,
                    spacing: 8,
                    prefix: "Downloading \(selectedChoice.displayName) model… "
                )
                Button("Cancel") { downloader.cancel() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentPink)
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: 420)
        case .done:
            Label("\(selectedChoice.displayName) model ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.dotGreen)
        }

        if let resolved = model.modelURL {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dotGreen)
                Text(resolved.path)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(Theme.gutterText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Capsule download button matching the sidebar's session capsule
    /// (start-session gradient, white label).
    private var downloadButton: some View {
        Button {
            downloader.start()
        } label: {
            Text("Download \(selectedChoice.displayName) speech model")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.Gradients.start))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}
