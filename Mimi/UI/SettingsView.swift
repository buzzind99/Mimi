import SwiftUI

/// App settings — "stacked cards" design (Mock 9 paper light / Mock 10
/// sakura dark): a single scrollable column of cards (notice, provider,
/// API key, appearance, ASR model, session) with no navigation chrome.
/// Buttons highlight pink on hover; appearance segments use a neutral wash.
struct SettingsView: View {
    var model: AppModel
    @Bindable private var settings: TranslationSettings
    @AppearanceSetting private var appearance
    @State private var keyDraft = ""
    @State private var keySaveFailed = false

    init(model: AppModel) {
        self.model = model
        _settings = Bindable(wrappedValue: model.translationSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            settingsDivider()
            ScrollView {
                cards
                    .padding(.vertical, 24)
            }
        }
        .frame(
            minWidth: 420, idealWidth: 460, maxWidth: 580,
            minHeight: 720, idealHeight: 800
        )
        .background(Palette.window)
        .preferredColorScheme(appearance.resolvedColorScheme)
        // A selection change applies immediately while a session is running:
        // the queue re-attaches the selected engine mid-drain (pending
        // sentences replay onto it). Covers both the provider rows and the
        // save-key auto-select — both mutate `selectedProvider`.
        .onChange(of: settings.selectedProvider) {
            keyDraft = ""
            keySaveFailed = false
            model.translationProviderDidChange()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(
                    LinearGradient(
                        colors: [Palette.accent, Palette.accentViolet],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.primaryText)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Palette.headerBar)
    }

    // MARK: - Cards

    private var cards: some View {
        VStack(spacing: 16) {
            noticeCard
            providerCard
            if settings.selectedProvider.isExternal {
                SettingsKeyCard(
                    model: model, settings: settings,
                    keyDraft: $keyDraft, keySaveFailed: $keySaveFailed
                )
            }
            appearanceCard
            modelCard
            sessionCard
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private func row(label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.secondaryText)
            Spacer()
            value()
        }
    }

    // MARK: - Notice (privacy / external)

    @ViewBuilder
    private var noticeCard: some View {
        if settings.selectedProvider.isExternal {
            notice(
                icon: "arrow.up.forward.circle.fill",
                title: "External provider",
                body: "Sentences will be sent to \(settings.selectedProvider.displayName) for translation."
            )
        } else {
            notice(
                icon: "lock.shield.fill",
                title: "Private by default",
                body: "On-device translation keeps every sentence local."
            )
        }
    }

    private func notice(icon: String, title: String, body: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
                Text(body)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Palette.accent.opacity(0.3))
                )
        )
    }

    // MARK: - Provider

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardLabel("TRANSLATION · PROVIDER")
            ForEach(TranslationProvider.allCases) { provider in
                providerRow(provider)
            }
        }
        .padding(16)
        .settingsCardBackground()
    }

    private func providerRow(_ provider: TranslationProvider) -> some View {
        let selected = settings.selectedProvider == provider
        return Button {
            settings.select(provider)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: provider.settingsIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.primaryText.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Palette.tileFill)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(providerName(provider))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primaryText)
                    Text(provider.settingsDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.mutedText)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            tint: Palette.accent, opacity: 0.1
        )
    }

    private func providerName(_ provider: TranslationProvider) -> String {
        switch provider {
        case .apple: "Apple"
        case .google: "Google Translate"
        case .deepl: settings.deeplIsFreeTier ? "DeepL (Free)" : "DeepL"
        case .openrouter: "OpenRouter"
        }
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardLabel("APPEARANCE")
            HStack(spacing: 2) {
                appearanceSegment(.system, icon: "laptopcomputer")
                appearanceSegment(.light, icon: "sun.max")
                appearanceSegment(.dark, icon: "moon")
            }
            .padding(3)
            .background(Capsule().fill(Palette.segmentTrack))
        }
        .padding(16)
        .settingsCardBackground()
    }

    private func appearanceSegment(_ value: Appearance, icon: String) -> some View {
        let selected = appearance == value
        return Button {
            appearance = value
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(value.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Palette.primaryText : Palette.mutedText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if selected {
                    Capsule().fill(Palette.segmentFill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule(), isEnabled: !selected)
    }

    // MARK: - Model / session diagnostics

    /// A card per ASR model choice (select / download), the models folder,
    /// and a re-check action.
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardLabel("SPEECH MODEL")
            HStack(alignment: .top, spacing: 12) {
                ForEach(ASRModelChoice.allCases) { choice in
                    SettingsModelRow(choice: choice, model: model)
                }
            }
            settingsDivider()
            row(label: "Models folder") {
                Text(ModelLocator.modelsDirectory.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Spacer()
                SettingsPill(label: "Re-check model") {
                    Task { await model.refreshModelAvailability() }
                }
            }
        }
        .padding(16)
        .settingsCardBackground()
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardLabel("SESSION")
            row(label: "Entries") {
                Text("\(model.entries.count)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.primaryText)
            }
            settingsDivider()
            row(label: "Engine") {
                Text(
                    model.engineIsMock
                        ? "Mock (runtime not installed)"
                        : "CrispASR · \(model.asrModelSettings.selected.displayName) (Metal)"
                )
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.engineText)
            }
            settingsDivider()
            row(label: "Translation") {
                // Truthful mid-fallback: the suffix shows only while the
                // latched Apple engine is actually the active one — a manual
                // retry that re-engaged the external engine hides it. The
                // base label reads the attached provider (never the picker),
                // so it can't describe an engine the queue isn't using.
                Text(
                    settings.activeEngineDescription(
                        fallbackActive:
                        model.translationFallbackActive &&
                            model.activeTranslationEngine == .apple,
                        attachedProvider: model.activeExternalProvider
                    )
                )
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Palette.primaryText)
            }
        }
        .padding(16)
        .settingsCardBackground()
    }
}
