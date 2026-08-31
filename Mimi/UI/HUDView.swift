import SwiftUI

/// Floating HUD content: active JP partial/final on top, EN translation
/// below. Hosted by `HUDHostingView` inside `HUDPanel` (HUDWindow.swift).
struct HUDView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LivePartialState
    @ObservedObject var panel: HUDPanel
    @ReadingAnnotationSetting private var readingAnnotation

    /// Set on offscreen measurement copies: fixes the layout width so the
    /// measured ideal height reflects text wrapped at the real HUD width.
    var fixedWidth: CGFloat?

    var body: some View {
        if let fixedWidth {
            hudContent.frame(width: fixedWidth, alignment: .topLeading)
        } else {
            hudContent
        }
    }

    private var hudContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            liveSection
                .padding(.bottom, 8)
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .padding(.bottom, 8)
            completedSection
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(panel.locked ? 0.08 : 0.35), lineWidth: 1)
        )
        .frame(minWidth: 360, minHeight: 170)
        .overlay(alignment: .topTrailing) { padlockButton }
    }

    /// Pinned top-trailing with 6pt padding; HUDHostingView.unlockRegion
    /// mirrors this rect so it stays clickable while locked.
    private var padlockButton: some View {
        Button {
            panel.locked.toggle()
        } label: {
            Image(systemName: panel.locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .help(panel.locked ? "Unlock to move/resize (HUD is click-through when locked)" : "Lock (click-through)")
    }

    private var liveSection: some View {
        Group {
            if !live.partial.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if readingAnnotation != .none {
                        RubyTextView(
                            text: live.partial,
                            annotation: readingAnnotation,
                            surfaceFont: .system(size: 15),
                            annotationFont: .system(size: 11, design: .monospaced),
                            annotationColor: .secondary,
                            reservesAnnotationLine: true
                        )
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(live.partial)
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Listening…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
    }

    /// Translated entries only; finalized-but-untranslated sentences never
    /// enter the cycle (the view doesn't move until their translation lands).
    private var translatedEntries: [SessionEntry] {
        model.entries.filter { $0.joinedTranslations != nil }
    }

    private var completedSection: some View {
        Group {
            let entries = translatedEntries
            if entries.isEmpty {
                Text("Waiting for the first sentence…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    entryView(displayedEntry(in: entries))
                    historyButtons(entries: entries)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The pinned entry while browsing history; otherwise (nil pin, or a pin
    /// that no longer resolves) the latest translated entry.
    private func displayedEntry(in entries: [SessionEntry]) -> SessionEntry {
        if let pinned = model.hudPinnedIndex,
           let at = entries.firstIndex(where: { $0.sentence.index == pinned })
        {
            return entries[at]
        }
        return entries[entries.count - 1]
    }

    private func entryView(_ entry: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if readingAnnotation != .none {
                Text(SessionClock.timestamp(entry.sentence.startS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                RubyTextView(
                    text: entry.sentence.text,
                    annotation: readingAnnotation,
                    surfaceFont: .system(size: 14),
                    annotationFont: .system(size: 11, design: .monospaced),
                    annotationColor: .secondary.opacity(0.8)
                )
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SessionClock.timestamp(entry.sentence.startS))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(entry.sentence.text)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let en = entry.joinedTranslations {
                Text(en)
                    .font(.system(size: 13))
                    .foregroundStyle(.teal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Right-side history cycling. Up = newer (disabled at latest, so the
    /// cursor follows new translations); down = older (pins to that exact
    /// sentence, so new translations never move the view).
    private func historyButtons(entries: [SessionEntry]) -> some View {
        let newest = entries[entries.count - 1].sentence.index
        let oldest = entries[0].sentence.index
        let pinned = model.hudPinnedIndex
        let atLatest = pinned == nil || pinned == newest
        let atOldest = entries.count < 2 || pinned == oldest
        return VStack(spacing: 2) {
            historyButton(
                icon: "chevron.up",
                help: "Newer translation",
                disabled: atLatest
            ) {
                cycleHistory(entries: entries, step: 1)
            }
            historyButton(
                icon: "chevron.down",
                help: "Older translation",
                disabled: atOldest
            ) {
                cycleHistory(entries: entries, step: -1)
            }
        }
        .padding(.top, 1)
    }

    /// Steps the pin one translated entry up/down. Stepping onto the newest
    /// entry clears the pin (re-follows latest, re-disabling up).
    private func cycleHistory(entries: [SessionEntry], step: Int) {
        let current = model.hudPinnedIndex ?? entries[entries.count - 1].sentence.index
        guard let at = entries.firstIndex(where: { $0.sentence.index == current }) else {
            return
        }
        let next = at + step
        guard entries.indices.contains(next) else { return }
        model.hudPinnedIndex = next == entries.count - 1 ? nil : entries[next].sentence.index
    }

    private func historyButton(
        icon: String, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(disabled ? .tertiary : .secondary)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}
