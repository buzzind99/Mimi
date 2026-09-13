import SwiftUI

/// App settings — "stacked cards" design: a single scrollable column of cards
/// (notice, provider, API key, appearance, ASR model, session) with no
/// navigation chrome. Buttons highlight pink on hover; appearance segments use
/// a neutral wash.
struct SettingsView: View {
    var model: AppModel
    @Bindable private var settings: TranslationSettings
    @AppearanceSetting private var appearance
    @State private var keyDraft = ""
    @State private var keySaveFailed = false
    /// An external provider being set up but not yet configured: its key
    /// card is shown, but the selection (checkmark) stays on the current
    /// provider until a key is saved and the connection test succeeds.
    @State private var pendingProvider: TranslationProvider?
    /// A configured external provider whose key is being verified before the
    /// selection may move to it (row click → live probe). Its row shows a
    /// checking spinner; a stale outcome (another row clicked mid-probe) is
    /// discarded.
    @State private var verifyingProvider: TranslationProvider?

    /// The provider whose card (key entry + privacy notice) is displayed:
    /// the pending one while it's being configured, otherwise the selection.
    private var displayedProvider: TranslationProvider {
        pendingProvider ?? settings.selectedProvider
    }

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
            minWidth: 420, idealWidth: 460, maxWidth: 560,
            minHeight: 720, idealHeight: 800
        )
        .background(Palette.window)
        .preferredColorScheme($appearance.resolvedColorScheme)
        // A selection change applies immediately while a session is running:
        // the queue re-attaches the selected engine mid-drain (pending
        // sentences replay onto it). Selection changes come from provider-row
        // picks on configured providers and from a verified key selecting its
        // provider on the key card's post-save connection test.
        .onChange(of: settings.selectedProvider) {
            pendingProvider = nil
            keyDraft = ""
            keySaveFailed = false
            model.translationProviderDidChange()
        }
        // The Settings scene keeps its window — and this view's @State —
        // cached after close, so transient card state survives a reopen and
        // the key card would come back stuck on the last-clicked pending
        // provider. Becoming key is the reopen signal (the window auto-closes
        // on resign-key, so it never regains key while open); reset so the
        // card reflects the active provider again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  SettingsWindowController.isSettingsWindow(window)
            else { return }
            pendingProvider = nil
            verifyingProvider = nil
            keyDraft = ""
            keySaveFailed = false
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
        .padding(.leading, 52)
        .padding(.trailing, 28)
        .padding(.vertical, 14)
        .background(Palette.headerBar)
    }

    // MARK: - Cards

    private var cards: some View {
        VStack(spacing: 16) {
            noticeCard
            providerCard
            if displayedProvider.isExternal {
                SettingsKeyCard(
                    model: model, settings: settings, provider: displayedProvider,
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
        if displayedProvider.isExternal {
            notice(
                icon: "arrow.up.forward.circle.fill",
                title: "External provider",
                body: "Sentences will be sent to \(displayedProvider.displayName) for translation."
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
        .cardSurface(fill: Palette.accent.opacity(0.08), stroke: Palette.accent.opacity(0.3))
    }

    // MARK: - Provider

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("TRANSLATION · PROVIDER", color: Palette.label)
            ForEach(TranslationProvider.allCases) { provider in
                providerRow(provider)
            }
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }

    private func providerRow(_ provider: TranslationProvider) -> some View {
        let selected = settings.selectedProvider == provider
        return Button {
            // Apple and the already-selected provider select immediately
            // (the latter is effectively a no-op that dismisses any key
            // card). A configured external provider is verified first: the
            // checkmark moves only once a live probe confirms its key still
            // works — failure opens its key card with the recorded error. An
            // unconfigured external provider opens its key card; the
            // checkmark moves once a key is saved and the connection test
            // succeeds (the key card's success path selects it).
            if provider == .apple || settings.selectedProvider == provider {
                pendingProvider = nil
                verifyingProvider = nil
                settings.select(provider)
            } else if settings.hasKey(for: provider) {
                verifyThenSelect(provider)
            } else {
                pendingProvider = provider
                verifyingProvider = nil
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: provider.settingsIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Palette.accent : Palette.primaryText.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Palette.tileFill)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.settingsName(deeplIsFreeTier: settings.deeplIsFreeTier))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primaryText)
                    Text(provider.settingsDetail(hasKey: settings.hasKey(for: provider)))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.mutedText)
                }
                Spacer()
                if verifyingProvider == provider {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Connecting…")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.mutedText)
                    }
                } else if selected {
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

    /// Probe-then-select for a configured external provider row: the
    /// selection moves only if the live probe verifies the key (via
    /// `AppModel.verifyAndSelectTranslationProvider`); failure opens the key
    /// card, where the recorded failure and Remove/Test actions show.
    private func verifyThenSelect(_ provider: TranslationProvider) {
        guard verifyingProvider != provider else { return }
        verifyingProvider = provider
        Task {
            let verified = await model.verifyAndSelectTranslationProvider(provider)
            guard verifyingProvider == provider else { return }
            verifyingProvider = nil
            if !verified {
                pendingProvider = provider
            }
        }
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("APPEARANCE", color: Palette.label)
            ModePicker(
                help: "Window appearance — System follows the macOS setting",
                modes: Appearance.allCases,
                selection: $appearance.binding,
                label: \.label,
                icon: { $0.systemImage },
                track: Palette.segmentTrack,
                selectedFill: Palette.segmentFill,
                unselectedColor: Palette.mutedText
            )
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }

    // MARK: - Model / session diagnostics

    /// A card per ASR model choice (select / download), the models folder,
    /// and a re-check action.
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("SPEECH MODEL", color: Palette.label)
            HStack(alignment: .top, spacing: 12) {
                ForEach(ASRModelChoice.allCases) { choice in
                    SettingsModelRow(choice: choice, model: model)
                }
            }
            HStack {
                Spacer()
                SettingsPill(label: "Re-check model") {
                    Task { await model.refreshModelAvailability() }
                }
                .padding(.top, 6)
            }
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("SESSION", color: Palette.label)
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
        .cardSurface(shadow: Palette.cardShadow)
    }
}
