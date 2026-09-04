import SwiftUI

/// App settings: model/session diagnostics (previously inline in
/// `MimiApp.swift`) plus the Translation section — provider picker, per
/// provider key entry (straight to the Keychain on save, never held beyond
/// the field), OpenRouter model, connection test, and a privacy notice while
/// an external provider is selected.
struct SettingsView: View {
    var model: AppModel
    @Bindable private var settings: TranslationSettings
    @State private var keyDraft = ""
    @State private var keySaveFailed = false
    @State private var isTestingConnection = false

    init(model: AppModel) {
        self.model = model
        _settings = Bindable(wrappedValue: model.translationSettings)
    }

    var body: some View {
        Form {
            translationSection
            modelSection
            sessionSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 480)
        .onChange(of: settings.selectedProvider) {
            keyDraft = ""
            keySaveFailed = false
        }
    }

    // MARK: - Translation

    private var translationSection: some View {
        Section("Translation") {
            LabeledContent("Currently using") {
                // Truthful mid-fallback: the suffix shows only while the
                // latched Apple engine is actually the active one — a manual
                // retry that re-engaged the external engine hides it.
                Text(
                    settings.activeEngineDescription(
                        fallbackActive:
                        model.translationFallbackActive &&
                            model.activeTranslationEngine == .apple
                    )
                )
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Picker("Provider", selection: providerBinding) {
                ForEach(TranslationProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            providerForm

            if settings.selectedProvider.isExternal {
                Text("Sentences will be sent to \(settings.selectedProvider.displayName) for translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Binding for the read-only published selection; persists via `select`.
    private var providerBinding: Binding<TranslationProvider> {
        Binding(
            get: { settings.selectedProvider },
            set: { settings.select($0) }
        )
    }

    @ViewBuilder
    private var providerForm: some View {
        switch settings.selectedProvider {
        case .apple:
            EmptyView()
        case .openrouter:
            LabeledContent("Model") {
                TextField("tencent/hy-mt2-30b-a3b", text: $settings.openRouterModel)
                    .textFieldStyle(.roundedBorder)
            }
            keyEntry
        case .google, .deepl:
            keyEntry
        }
    }

    private var keyEntry: some View {
        let provider = settings.selectedProvider
        return Group {
            if settings.hasKey(for: provider) {
                LabeledContent("API key") {
                    HStack {
                        Text(maskedKeyHint(for: provider))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Button("Remove") {
                            settings.removeKey(for: provider)
                            keyDraft = ""
                        }
                    }
                }
                connectionTestRow(provider)
            } else {
                LabeledContent("API key") {
                    HStack {
                        SecureField("Paste API key", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            saveKeyDraft(for: provider)
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if keySaveFailed {
                    Text("Couldn't save the key to the Keychain.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func connectionTestRow(_ provider: TranslationProvider) -> some View {
        HStack {
            Button("Test") {
                runConnectionTest(for: provider)
            }
            .disabled(isTestingConnection)

            switch settings.testResult(for: provider) {
            case .success:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case let .failure(message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        }
    }

    // MARK: - Actions

    /// Writes the draft key to the secure store. The draft is cleared only
    /// after a successful save so a Keychain failure (auth denied, storage
    /// error) doesn't lose the paste; the failure surfaces as an inline
    /// caption until the next attempt or provider switch.
    private func saveKeyDraft(for provider: TranslationProvider) {
        let key = keyDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        do {
            try settings.saveKey(key, for: provider)
            keyDraft = ""
            keySaveFailed = false
        } catch {
            keySaveFailed = true
        }
    }

    private func runConnectionTest(for provider: TranslationProvider) {
        guard let key = settings.key(for: provider) else {
            settings.setTestResult(.failure("No API key configured"), for: provider)
            return
        }
        isTestingConnection = true
        Task {
            let result = await TranslationConnectionTester.test(provider: provider, key: key)
            let message = switch result {
            case .success: ConnectionTestResult.success
            case let .failure(error): ConnectionTestResult.failure(error.statusMessage)
            }
            settings.setTestResult(message, for: provider)
            isTestingConnection = false
        }
    }

    private func maskedKeyHint(for provider: TranslationProvider) -> String {
        guard let hint = settings.keyHint(for: provider) else { return "Saved" }
        return "•••• \(hint)"
    }

    // MARK: - Model / session diagnostics

    /// One row per ASR model choice: a downloaded + verified model can be
    /// selected (unless a session is running/starting — the change applies
    /// at the next session start, like the translation provider), and the
    /// active one is marked "In use". Missing models get an inline download
    /// (`arrow.down.circle`) with progress, cancel, and error + retry.
    private var modelSection: some View {
        Section("Model") {
            ForEach(ASRModelChoice.allCases) { choice in
                ModelRow(choice: choice, model: model)
            }
            LabeledContent("Models folder") {
                Text(ModelLocator.modelsDirectory.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Re-check model") {
                Task { await model.refreshModelAvailability() }
            }
        }
    }

    private var sessionSection: some View {
        Section("Session") {
            LabeledContent("Entries") { Text("\(model.entries.count)") }
            LabeledContent("Engine") {
                Text(
                    model.engineIsMock
                        ? "Mock (runtime not installed)"
                        : "CrispASR · \(model.asrModelSettings.selected.displayName) (Metal)"
                )
            }
        }
    }
}

/// A single model row in the Settings Model section (see `modelSection`).
/// Owns one `ModelDownloader` per choice so downloads run (and resume)
/// independently; a completed Settings download auto-selects the model.
@MainActor
private struct ModelRow: View {
    let choice: ASRModelChoice
    var model: AppModel
    @State private var downloader: ModelDownloader

    init(choice: ASRModelChoice, model: AppModel) {
        self.choice = choice
        self.model = model
        _downloader = State(initialValue: ModelDownloader(choice: choice))
    }

    private var resolvedURL: URL? {
        model.modelAvailability[choice]
    }

    private var isInUse: Bool {
        model.asrModelSettings.selected == choice
    }

    /// A selection change applies at the next session start; mid-session
    /// (.running/.starting) it is disabled.
    private var selectionDisabled: Bool {
        resolvedURL == nil || model.phase == .running || model.phase == .starting
    }

    /// Selection and download live side by side (not nested): disabling the
    /// row while a model is missing would otherwise also disable the very
    /// download button meant to fix that.
    var body: some View {
        HStack {
            selectionButton
            Spacer()
            downloadControls
        }
        .onChange(of: downloader.state) { _, state in
            // A finished Settings download is explicit intent: verify the
            // new file and auto-select it (see `adoptDownloadedModel`).
            if case .done = state {
                Task { await model.adoptDownloadedModel(choice) }
            }
        }
    }

    private var selectionButton: some View {
        Button {
            guard !selectionDisabled, !isInUse else { return }
            model.selectModel(choice)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(choice.displayName)
                    if isInUse {
                        Label("In use", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.teal)
                    }
                }
                statusLine
                if case let .failed(message) = downloader.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(selectionDisabled)
    }

    /// Download affordances for a missing model; these stay enabled even
    /// while selection is disabled (mid-session or not-yet-downloaded).
    @ViewBuilder
    private var downloadControls: some View {
        switch downloader.state {
        case .downloading:
            Button("Cancel") { downloader.cancel() }
                .buttonStyle(.link)
                .font(.caption)
        case .failed:
            Button("Retry") { downloader.start() }
                .font(.caption)
        default:
            if resolvedURL == nil {
                Button {
                    downloader.start()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("Download \(choice.displayName) model (\(choice.approximateSize))")
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch downloader.state {
        case let .downloading(_, bytes, total):
            if let total, total > 0 {
                ProgressView(value: Double(bytes), total: Double(total))
                Text(
                    bytes.formatted(.byteCount(style: .memory)) + " / "
                        + total.formatted(.byteCount(style: .memory))
                )
                .font(.caption.monospacedDigit())
            } else {
                ProgressView()
            }
        // Stale `.done` (file deleted externally after a completed download)
        // must not read "Downloaded": fall through to the missing branch.
        case .done where resolvedURL != nil:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        default:
            if resolvedURL != nil {
                Text(choice.modelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not downloaded")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
