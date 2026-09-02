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
                // RubyTextView renders .none as plain text, so one call
                // covers every annotation mode.
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
        guard let index = HUDHistory.displayedIndex(in: entries, pinned: model.hudPinnedIndex),
              let entry = entries.first(where: { $0.sentence.index == index }) else
        {
            return entries[entries.count - 1]
        }
        return entry
    }

    private func entryView(_ entry: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if readingAnnotation != .none {
                Text(SessionClock.timestamp(entry.sentence.startS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                jpText(of: entry)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SessionClock.timestamp(entry.sentence.startS))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    jpText(of: entry)
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

    /// Shared JP text call (RubyTextView renders .none as plain text).
    private func jpText(of entry: SessionEntry) -> some View {
        RubyTextView(
            text: entry.sentence.text,
            annotation: readingAnnotation,
            surfaceFont: .system(size: 14),
            annotationFont: .system(size: 11, design: .monospaced),
            annotationColor: .secondary.opacity(0.8)
        )
        .foregroundStyle(.white)
    }

    /// Right-side history cycling. Up = newer (disabled at latest, so the
    /// cursor follows new translations); down = older (pins to that exact
    /// sentence, so new translations never move the view).
    private func historyButtons(entries: [SessionEntry]) -> some View {
        VStack(spacing: 2) {
            historyButton(
                icon: "chevron.up",
                help: "Newer translation",
                disabled: !HUDHistory.canStepNewer(entries: entries, pinned: model.hudPinnedIndex)
            ) {
                cycleHistory(entries: entries, step: 1)
            }
            historyButton(
                icon: "chevron.down",
                help: "Older translation",
                disabled: !HUDHistory.canStepOlder(entries: entries, pinned: model.hudPinnedIndex)
            ) {
                cycleHistory(entries: entries, step: -1)
            }
        }
        .padding(.top, 1)
    }

    /// Steps the pin one translated entry up/down. Stepping onto the newest
    /// entry clears the pin (re-follows latest, re-disabling up).
    private func cycleHistory(entries: [SessionEntry], step: Int) {
        model.hudPinnedIndex = HUDHistory.cycle(
            entries: entries, pinned: model.hudPinnedIndex, step: step
        )
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
