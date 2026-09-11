import SwiftUI

/// The API key card: per-provider key entry (straight to the Keychain on
/// save, never held beyond the field), an opaque dot mask for a saved key
/// with Remove/Test actions, and the OpenRouter model field. Shown for
/// external providers — the selected one, or a pending (not yet configured)
/// one being set up. Saving a key auto-runs a connection test; a successful
/// test (auto or via the Test button) selects the provider and activates its
/// engine immediately.
struct SettingsKeyCard: View {
    var model: AppModel
    @Bindable var settings: TranslationSettings
    let provider: TranslationProvider
    @Binding var keyDraft: String
    @Binding var keySaveFailed: Bool
    @State private var isTestingConnection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel(provider.displayName.uppercased(), color: Palette.label)
            if settings.hasKey(for: provider) {
                savedKeyRows()
            } else {
                keyEntryRows()
            }
            if provider == .openrouter {
                modelField
            }
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }

    // MARK: - Saved key

    @ViewBuilder
    private func savedKeyRows() -> some View {
        HStack(spacing: 8) {
            Text("••••••••••••••••")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .settingsFieldBackground()
            SettingsPill(label: "Remove") {
                settings.removeKey(for: provider)
                keyDraft = ""
            }
            SettingsPill(label: "Test", isEnabled: !isTestingConnection) {
                runConnectionTest(for: provider)
            }
        }
        HStack(spacing: 6) {
            connectionStatus(provider)
            Spacer()
            Text("Key is stored securely in the Keychain and never written to disk.")
                .font(.system(size: 10))
                .foregroundStyle(Palette.mutedText)
        }
    }

    // MARK: - Key entry

    @ViewBuilder
    private func keyEntryRows() -> some View {
        HStack(spacing: 8) {
            SecureField("Paste API key", text: $keyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .settingsFieldBackground()
            SettingsPill(
                label: "Save", prominent: true,
                isEnabled: !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty
            ) {
                saveKeyDraft(for: provider)
            }
        }
        if keySaveFailed {
            Text("Couldn't save the key to the Keychain.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.statusRed)
        } else {
            HStack(spacing: 6) {
                Spacer()
                Text("Key is stored securely in the Keychain and never written to disk.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.mutedText)
            }
        }
    }

    // MARK: - OpenRouter model

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 7) {
            settingsDivider()
            KickerLabel("MODEL", color: Palette.label, size: 9.5)
            HStack(spacing: 8) {
                TextField("tencent/hy-mt2-30b-a3b", text: $settings.openRouterModel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .settingsFieldBackground()
                // The model string persists as typed; Save re-attaches the
                // engine so a changed model takes effect on a live session.
                SettingsPill(label: "Save", prominent: true) {
                    model.translationProviderDidChange()
                }
            }
        }
    }

    // MARK: - Connection test

    @ViewBuilder
    private func connectionStatus(_ provider: TranslationProvider) -> some View {
        if isTestingConnection {
            ProgressView()
                .controlSize(.mini)
            Text("Testing…")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
        } else {
            switch settings.testResult(for: provider) {
            case .success:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text("Connected")
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.statusGreen)
            case let .failure(message):
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                    Text(message)
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.statusRed)
            case nil:
                EmptyView()
            }
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
            // A verified key configures the provider: selecting it moves the
            // checkmark and re-attaches its engine via SettingsView's
            // onChange. Already-selected providers (re-test after a key
            // fix) re-attach directly.
            if case .success = result {
                if settings.selectedProvider == provider {
                    model.translationProviderDidChange()
                } else {
                    settings.select(provider)
                }
            }
            isTestingConnection = false
        }
    }

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
            // Auto-check the connection on save; a verified key activates
            // the provider's engine right away (see `runConnectionTest`).
            runConnectionTest(for: provider)
        } catch {
            keySaveFailed = true
        }
    }
}
