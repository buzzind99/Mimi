import SwiftUI

/// A model card in the Settings Speech Model card (see
/// `SettingsView.modelCard`). Owns one `ModelDownloader` per choice so
/// downloads run (and resume) independently; a completed Settings download
/// auto-selects the model.
@MainActor
struct SettingsModelRow: View {
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

    /// The whole card is the selection button; download affordances float on
    /// top as an overlay, outside the button's `.disabled` — selection and
    /// download stay independent (a missing model must remain downloadable
    /// precisely because that is what disables selection).
    var body: some View {
        card
            .overlay(alignment: .topTrailing) {
                downloadControls.padding(12)
            }
            .onChange(of: downloader.state) { _, state in
                // A finished Settings download is explicit intent: verify the
                // new file and auto-select it (see `adoptDownloadedModel`).
                if case .done = state {
                    Task { await model.adoptDownloadedModel(choice) }
                }
            }
    }

    private var card: some View {
        Button {
            guard !selectionDisabled, !isInUse else { return }
            model.selectModel(choice)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(choice.displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.primaryText)
                    if isInUse {
                        Label("In use", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.accent)
                    }
                }
                Text(choice.modelName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.primaryText)
                Text(choice.blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                footer
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectionDisabled)
        .background(cardBackground)
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 12, style: .continuous),
            isEnabled: !selectionDisabled && !isInUse,
            tint: Palette.accent, opacity: 0.06
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isInUse ? Palette.accent.opacity(0.08) : Palette.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isInUse ? Palette.accent.opacity(0.55) : Palette.cardStroke)
            )
    }

    /// Download affordances for a missing model; these stay enabled even
    /// while selection is disabled (mid-session or not-yet-downloaded).
    @ViewBuilder
    private var downloadControls: some View {
        switch downloader.state {
        case .downloading:
            SettingsPill(label: "Cancel") { downloader.cancel() }
        case .failed:
            SettingsPill(label: "Retry") { downloader.start() }
        default:
            if resolvedURL == nil {
                Button {
                    downloader.start()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.accent)
                        .padding(6)
                        .background(Circle().fill(Palette.pillFill))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(Circle(), tint: Palette.accent, opacity: 0.12)
                .help("Download \(choice.displayName) model (\(choice.approximateSize))")
            }
        }
    }

    /// Size · status line pinned to the card's bottom edge; download progress
    /// and failures replace it in place.
    @ViewBuilder
    private var footer: some View {
        switch downloader.state {
        case let .downloading(_, bytes, total):
            VStack(alignment: .leading, spacing: 5) {
                if let total, total > 0 {
                    ProgressView(value: Double(bytes), total: Double(total))
                        .tint(Palette.accent)
                    Text(
                        bytes.formatted(.byteCount(style: .memory)) + " / "
                            + total.formatted(.byteCount(style: .memory))
                    )
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.secondaryText)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        case let .failed(message):
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.statusRed)
                .fixedSize(horizontal: false, vertical: true)
        default:
            // Stale `.done` (file deleted externally after a completed
            // download) must not read "downloaded": fall through to the
            // missing branch.
            Text("\(choice.approximateSize) · \(resolvedURL != nil ? "downloaded" : "not downloaded")")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(resolvedURL != nil ? Palette.mutedText : Palette.statusRed)
        }
    }
}
