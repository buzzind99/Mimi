import SwiftUI

/// App settings: model/session diagnostics (previously inline in
/// `MimiApp.swift`) plus the Translation section — provider picker, per
/// provider key entry (straight to the Keychain on save, never held beyond
/// the field), OpenRouter model, connection test, and a privacy notice while
/// an external provider is selected.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: TranslationSettings
    @State private var keyDraft = ""
    @State private var keySaveFailed = false
    @State private var isTestingConnection = false

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.translationSettings)
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
                Text(settings.activeEngineDescription(fallbackActive: model.translationFallbackActive))
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

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Status") {
                if let url = model.modelURL {
                    Text(url.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not downloaded").foregroundStyle(.orange)
                }
            }
            LabeledContent("Model") {
                Text(ModelLocator.modelID)
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
                Text(model.engineIsMock ? "Mock (runtime not installed)" : "CrispASR · Qwen3-ASR 0.6B (Metal)")
            }
        }
    }
}
