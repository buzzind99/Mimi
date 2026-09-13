import SwiftUI

/// The onboarding variant of the settings model card (`SettingsModelRow`):
/// selection is always allowed (it picks the download target, not a
/// ready-to-run model), the shared `downloader` follows the picked card, and
/// download affordances appear only on the picked card. The picked state
/// shows as the card's accent fill/stroke — no "In use" pill or checkmark —
/// and the footer shows only the size (no downloaded/not-downloaded story).
struct OnboardingModelRow: View {
    let choice: ASRModelChoice
    var model: AppModel
    /// Shared with `OnboardingView`, which resets it when the selection
    /// changes: switching targets abandons any in-flight download.
    let downloader: ModelDownloader

    private var resolvedURL: URL? {
        model.modelAvailability[choice]
    }

    private var isPicked: Bool {
        model.asrModelSettings.selected == choice
    }

    /// The whole card is the selection button; download affordances float on
    /// top as an overlay, outside the button's label.
    var body: some View {
        card
            .overlay(alignment: .topTrailing) {
                if isPicked {
                    downloadControls.padding(12)
                }
            }
    }

    private var card: some View {
        Button {
            guard !isPicked else { return }
            model.asrModelSettings.select(choice)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(choice.displayName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.primaryText)
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
        .cardSurface(
            radius: 12,
            fill: isPicked ? Palette.accent.opacity(0.08) : Palette.cardFill,
            stroke: isPicked ? Palette.accent.opacity(0.55) : Palette.cardStroke
        )
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 12, style: .continuous),
            isEnabled: !isPicked,
            tint: Palette.accent, opacity: 0.06
        )
    }

    /// Download affordances for the picked card while its model is missing.
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

    /// Size line pinned to the card's bottom edge; download progress and
    /// failures replace it in place — on the picked card only, since both
    /// cards observe the same shared downloader.
    @ViewBuilder
    private var footer: some View {
        if isPicked {
            switch downloader.state {
            case let .downloading(_, bytes, total):
                ModelDownloadProgressView(bytes: bytes, total: total)
            case let .failed(message):
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.statusRed)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                sizeLine
            }
        } else {
            sizeLine
        }
    }

    private var sizeLine: some View {
        Text(choice.approximateSize)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Palette.mutedText)
    }
}
