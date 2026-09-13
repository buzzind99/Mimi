import SwiftUI

/// Onboarding: explains screen-recording permission + system audio capture,
/// then lets the user pick + download the ASR model with the same cards as
/// Settings (`SettingsModelRow`: per-choice download with progress / resume
/// / retry; a completed download auto-selects its model, which resolves
/// `phase` out of `.needsModel` and advances to the main shell). A manually
/// dropped-in GGUF is picked up by `ModelLocator.resolve(for:)` on the next
/// availability refresh.
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

            modelCard

            settingsSwapHint

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

    private var selectedChoice: ASRModelChoice {
        model.asrModelSettings.selected
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
                Text(
                    "A speech model downloads once from Hugging Face and is stored in Application "
                        + "Support. Pick a card below — Lite is the smaller default."
                )
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

    /// The onboarding model card: one card per choice sharing the selection-
    /// following `downloader` (see `OnboardingModelRow`), in the same
    /// container as `SettingsView.modelCard`. Fixed at the permission card's
    /// width so a wider window stretches the surrounding layout, not the
    /// picker.
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("SPEECH MODEL", color: Palette.label)
            HStack(alignment: .top, spacing: 12) {
                ForEach(ASRModelChoice.allCases) { choice in
                    OnboardingModelRow(choice: choice, model: model, downloader: downloader)
                }
            }
        }
        .padding(16)
        .frame(width: 520)
        .cardSurface(shadow: Palette.cardShadow)
    }

    private var settingsSwapHint: some View {
        Text("You can swap the model later in Settings.")
            .font(.system(size: 10))
            .foregroundStyle(Theme.gutterText)
            .multilineTextAlignment(.center)
    }
}
