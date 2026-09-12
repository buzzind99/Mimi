import SwiftUI

// MARK: - Shared popover binding

extension AppModel {
    /// The "get: source match / set: dismiss" binding behind every
    /// dictionary-popover presentation (the live strip and each transcript
    /// word anchor): true only while the selection's anchor is `source`;
    /// dismissal (and Escape) clears the selection only when this surface
    /// owns it, so a stale binding from a virtualized-off-screen row can
    /// never clobber a newer selection.
    func lookupPopoverBinding(for source: SelectedLookup.Source) -> Binding<Bool> {
        Binding(
            get: { self.selectedLookup?.source == source },
            set: { isPresented in
                if !isPresented {
                    self.dismissLookupPopover(source: source)
                }
            }
        )
    }
}

// MARK: - Hosts

/// The popover presented by the surface that owns the selection: the shared
/// entry content with the labeled Copy pill, or the not-found state with
/// its related suggestions.
struct DictionaryPopoverView: View {
    var model: AppModel
    let selected: SelectedLookup

    var body: some View {
        Group {
            switch selected.content {
            case let .found(result, also, origin):
                if let entry = result.entries[safe: selected.entryIndex] {
                    DictionaryEntryContentView(
                        entry: entry,
                        entryCount: result.entries.count,
                        entryIndex: selected.entryIndex,
                        also: also,
                        displayOrigin: origin,
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
            case let .notFound(surface, related):
                DictionaryNotFoundView(
                    surface: surface, related: related,
                    onSelectRelated: { model.selectAlsoPill($0) }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                KickerLabel("DICTIONARY")
                Spacer(minLength: 8)
                if let pinned = model.pinnedLookup,
                   case let .found(result, _, _) = pinned.content,
                   result.entries.count > 1
                {
                    DictionaryEntryPager(
                        entryIndex: pinned.entryIndex,
                        entryCount: result.entries.count,
                        onStep: { model.stepLookupEntry(to: $0) }
                    )
                }
            }
            // The pager's height is reserved even when it is absent, so the
            // header row never changes height between lookups.
            .frame(height: DictionaryEntryPager.height)
            .onHeightChange { labelHeight = $0 }
            if let pinned = model.pinnedLookup {
                pinnedContent(pinned, freeHeight: freeHeight)
            } else {
                emptyHint
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// The pinned content per state: the shared entry view for a found
    /// lookup, the not-found state with its related suggestions otherwise.
    /// The not-found block feeds the top-section probe so the (sense-less)
    /// viewport math stays settled while it is up.
    @ViewBuilder
    private func pinnedContent(_ pinned: PinnedLookup, freeHeight: CGFloat) -> some View {
        switch pinned.content {
        case let .found(result, also, origin):
            if let entry = result.entries[safe: pinned.entryIndex] {
                DictionaryEntryContentView(
                    entry: entry,
                    entryCount: result.entries.count,
                    entryIndex: pinned.entryIndex,
                    also: also,
                    displayOrigin: origin,
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
                emptyHint
            }
        case let .notFound(surface, related):
            DictionaryNotFoundView(
                surface: surface, related: related,
                onSelectRelated: { model.selectAlsoPill($0) }
            )
            .onHeightChange { topSectionHeight = $0 }
            .onAppear {
                // Probes this state doesn't mount keep the viewport
                // math at their zero-content values.
                alsoHeight = 0
                sensesContentHeight = 0
            }
        }
    }

    private var emptyHint: some View {
        Text("Tap a word in the transcript to see its definition here.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
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
