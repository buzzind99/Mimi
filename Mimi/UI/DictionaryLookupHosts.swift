import SwiftUI

// MARK: - Hosts

/// The popover presented by the surface that owns the selection: the shared
/// entry content with the labeled Copy pill.
struct DictionaryPopoverView: View {
    var model: AppModel
    let selected: SelectedLookup

    var body: some View {
        Group {
            if let entry = selected.result.entries[safe: selected.entryIndex] {
                DictionaryEntryContentView(
                    entry: entry,
                    entryCount: selected.result.entries.count,
                    entryIndex: selected.entryIndex,
                    also: model.pinnedLookup?.also ?? [],
                    senseLimit: nil,
                    glossLimit: nil,
                    copyPlacement: .pill,
                    onCopy: {
                        model.copySnippet(DictionaryContent.headword(of: entry) ?? "")
                    },
                    onSelectAlso: { model.selectAlsoPill($0) },
                    onStepEntry: { model.stepLookupEntry(to: $0) }
                )
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .topLeading)
        .background(Theme.toastBackground)
    }
}

/// The sidebar DICTIONARY card: last lookup pinned for the session, or an
/// empty state (header + hint) before the first hit. Never collapses the
/// slot; visibility itself is mode-gated by `SidebarView`.
///
/// Every sense and gloss is expanded; when they don't fit the free sidebar
/// space only the sense rows scroll — the headword/badges/pitch block above
/// and the "also:" row below stay fixed. The `GeometryReader` slot claims
/// the space the engine-mode `Spacer()` would take (`layoutPriority(1)` in
/// `SidebarView`), while the visible chrome keeps hugging its content.
struct DictionaryCardView: View {
    var model: AppModel

    /// Measured fixed-chrome pieces feeding `sensesViewport`: the
    /// DICTIONARY label, the entry's fixed top section, and the "also:"
    /// row. All are viewport-independent, so the derivation settles
    /// instead of feeding back.
    @State private var labelHeight: CGFloat = 0
    @State private var topSectionHeight: CGFloat = 0
    @State private var alsoHeight: CGFloat = 0
    /// Natural height of all sense rows — what the viewport clamps against.
    @State private var sensesContentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            card(freeHeight: geo.size.height)
        }
    }

    private func card(freeHeight: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                Text("DICTIONARY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .kerning(1.2)
                Spacer(minLength: 8)
                if let pinned = model.pinnedLookup, pinned.result.entries.count > 1 {
                    DictionaryEntryPager(
                        entryIndex: pinned.entryIndex,
                        entryCount: pinned.result.entries.count,
                        onStep: { model.stepLookupEntry(to: $0) }
                    )
                }
            }
            .onHeightChange { labelHeight = $0 }
            if let pinned = model.pinnedLookup,
               let entry = pinned.result.entries[safe: pinned.entryIndex]
            {
                DictionaryEntryContentView(
                    entry: entry,
                    entryCount: pinned.result.entries.count,
                    entryIndex: pinned.entryIndex,
                    also: pinned.also,
                    senseLimit: nil,
                    glossLimit: nil,
                    sensesViewportHeight: sensesViewport(freeHeight: freeHeight),
                    onTopSectionHeightChange: { topSectionHeight = $0 },
                    onAlsoHeightChange: { alsoHeight = $0 },
                    onSensesHeightChange: { sensesContentHeight = $0 },
                    copyPlacement: .icon,
                    showsEntryPager: false,
                    onCopy: {
                        model.copySnippet(DictionaryContent.headword(of: entry) ?? "")
                    },
                    onSelectAlso: { model.selectAlsoPill($0) },
                    onStepEntry: { model.stepLookupEntry(to: $0) }
                )
            } else {
                Text("Tap a word in the transcript to see its definition here.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardChrome)
    }

    /// Height for the senses viewport: the full row height when everything
    /// fits, otherwise whatever is left of the sidebar slot after the fixed
    /// chrome (card padding, label + gap, top section + gap, "also:" row +
    /// gap) and the engine-mode `Spacer` minimum below the card.
    private func sensesViewport(freeHeight: CGFloat) -> CGFloat {
        let chrome = 2 * 14 // card padding
            + labelHeight + 10
            + topSectionHeight + 8
            + alsoHeight + 8
        let room = max(0, freeHeight - chrome - 8)
        return min(sensesContentHeight, room)
    }
}
