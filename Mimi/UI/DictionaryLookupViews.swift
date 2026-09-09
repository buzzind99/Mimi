import SwiftUI

/// Pure content assembly shared by the dictionary popover and the sidebar
/// DICTIONARY card: derives display strings from a `JMDictEntry` under the
/// lookup-plan caps and the probe-fixed mappings (JLPT `≈N`, pitch pill
/// without an accent-type label, hatsuon omitted when it carries Wadoku
/// markup). Both hosts render through the same view so they can never
/// diverge.
enum DictionaryContent {
    static let maxGlossesPerSense = 3
    static let maxSenses = 5
    static let maxAlsoPills = 2

    /// Headword row: the kanji writing when present, else the reading.
    static func headword(of entry: JMDictEntry) -> String? {
        entry.keb ?? entry.reb
    }

    /// Probe-fixed JLPT display: `≈N{value}` (5 → ≈N5 … 1 → ≈N1); nil
    /// omits the badge.
    static func jlptBadge(_ jlpt: Int?) -> String? {
        guard let jlpt else { return nil }
        return "≈N\(jlpt)"
    }

    /// `hatsuon` renders verbatim only when free of the Wadoku markup
    /// markers (`< > [ ] ･ ~`); marked-up text omits the hatsuon part and
    /// the pill shows `zoPatts` alone.
    static func renderableHatsuon(_ hatsuon: String?) -> String? {
        guard let hatsuon, !hatsuon.isEmpty,
              !hatsuon.contains(where: { "<>[]･~".contains($0) })
        else { return nil }
        return hatsuon
    }

    /// Pitch pill v1: unmarked-up hatsuon (optional) + verbatim `zoPatts`
    /// (alphabet `H L h l ,` — never re-spaced). Nil when neither part
    /// exists, omitting the pill.
    struct PitchPill: Equatable {
        let hatsuon: String?
        let zoPatts: String?
    }

    static func pitchPill(for entry: JMDictEntry) -> PitchPill? {
        let hatsuon = renderableHatsuon(entry.hatsuon)
        let zo = entry.zoPatts.flatMap { $0.isEmpty ? nil : $0 }
        guard hatsuon != nil || zo != nil else { return nil }
        return PitchPill(hatsuon: hatsuon, zoPatts: zo)
    }

    /// Romaji line under the headword: kana→romaji over the reading; nil
    /// when the reading is missing or unmappable (no line).
    static func romaji(for entry: JMDictEntry) -> String? {
        entry.reb.flatMap { KanaRomaji.romaji(fromKana: $0) }
    }

    /// First tag of the stored comma-joined POS string.
    static func posLabel(_ pos: String?) -> String? {
        guard let pos, !pos.isEmpty else { return nil }
        return pos.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces)
    }

    /// Sense list capped at `limit` (nil = every sense), with the hidden
    /// count for the "+ N more senses" footer.
    static func truncatedSenses(
        _ senses: [JMDictSense], limit: Int? = DictionaryContent.maxSenses
    ) -> (visible: ArraySlice<JMDictSense>, hidden: Int) {
        guard let limit else { return (senses[...], 0) }
        let visible = senses.prefix(limit)
        return (visible, senses.count - visible.count)
    }

    /// Glosses of one sense capped (nil = every gloss), with the hidden count.
    static func truncatedGlosses(
        _ glosses: [String], limit: Int? = DictionaryContent.maxGlossesPerSense
    ) -> (visible: ArraySlice<String>, hidden: Int) {
        guard let limit else { return (glosses[...], 0) }
        let visible = glosses.prefix(limit)
        return (visible, glosses.count - visible.count)
    }

    /// "also:" shorter-hit pills, capped at two.
    static func truncatedAlso(_ also: [LookupResult]) -> ArraySlice<LookupResult> {
        also.prefix(maxAlsoPills)
    }
}

// MARK: - Shared entry content view

/// Where the host places the copy control inside the shared entry content.
enum DictionaryCopyPlacement {
    /// Popover: labeled Copy pill in the header row.
    case pill
    /// Sidebar card: small icon top-trailing of the header row.
    case icon
    /// No copy control.
    case none
}

/// The full dictionary entry composition — headword (+ reading), romaji,
/// badge row, pitch pill, numbered POS-labeled senses, "also:" pills, entry
/// pager — rendered identically by the popover and the sidebar card. The
/// card host scrolls only the sense rows (see `sensesViewportHeight`);
/// everything above them and the "also:" row below stay fixed.
struct DictionaryEntryContentView: View {
    let entry: JMDictEntry
    let entryCount: Int
    let entryIndex: Int
    let also: [LookupResult]
    /// Senses rendered (nil = every sense). The popover keeps the shared
    /// cap; the card passes nil to expand all.
    var senseLimit: Int? = DictionaryContent.maxSenses
    /// Glosses per sense (nil = every gloss).
    var glossLimit: Int? = DictionaryContent.maxGlossesPerSense
    /// When set, the sense rows render inside a vertical ScrollView framed
    /// to exactly this height — they scroll only when taller than it. The
    /// host derives it from the free sidebar space minus the fixed chrome.
    var sensesViewportHeight: CGFloat?
    /// Natural height of the fixed top section (header/romaji/badges/pitch).
    var onTopSectionHeightChange: (CGFloat) -> Void = { _ in }
    /// Natural height of the "also:" row (0 when absent).
    var onAlsoHeightChange: (CGFloat) -> Void = { _ in }
    /// Natural height of every sense row — the unclamped content height the
    /// viewport clamps against.
    var onSensesHeightChange: (CGFloat) -> Void = { _ in }
    var copyPlacement: DictionaryCopyPlacement = .none
    /// When false the host renders the entry pager itself (the sidebar card
    /// puts it on the DICTIONARY label row to free headword width).
    var showsEntryPager = true
    var onCopy: () -> Void = {}
    var onSelectAlso: (LookupResult) -> Void = { _ in }
    var onStepEntry: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topSection
                .onHeightChange { onTopSectionHeightChange($0) }
            sensesSection
            alsoSection
        }
    }

    private var headword: String {
        DictionaryContent.headword(of: entry) ?? entry.reb ?? "—"
    }

    private var reading: String? {
        entry.keb != nil ? entry.reb : nil
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: headword)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .textSelection(.disabled)
            if let reading {
                Text(verbatim: reading)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.annotationPink)
                    .lineLimit(1)
                    .textSelection(.disabled)
            }
            Spacer(minLength: 8)
            if entryCount > 1, showsEntryPager {
                entryPager
            }
            switch copyPlacement {
            case .pill:
                copyButton
            case .icon:
                copyIconButton
            case .none:
                EmptyView()
            }
        }
    }

    /// `◀ i/N ▶` walker over the entries a homograph candidate matched.
    private var entryPager: some View {
        DictionaryEntryPager(
            entryIndex: entryIndex,
            entryCount: entryCount,
            onStep: onStepEntry
        )
    }

    private var copyButton: some View {
        Button(action: onCopy) {
            Label("Copy", systemImage: "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.accentPink))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Copy the headword")
    }

    private var copyIconButton: some View {
        Button(action: onCopy) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(Theme.tileFill.clipShape(RoundedRectangle(cornerRadius: 6)))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Copy the headword")
    }

    @ViewBuilder
    private var badgeRow: some View {
        let badges = [
            entry.common ? "COMMON" : nil,
            DictionaryContent.jlptBadge(entry.jlpt)
        ].compactMap { $0 }
        if !badges.isEmpty {
            HStack(spacing: 6) {
                ForEach(badges, id: \.self) { badge in
                    DictionaryBadgeView(text: badge, color: badge == "COMMON" ? Theme.dotGreen : Theme.brandViolet)
                }
            }
        }
    }

    private func pitchPill(_ pitch: DictionaryContent.PitchPill) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
            if let hatsuon = pitch.hatsuon {
                Text(verbatim: hatsuon)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                Text(verbatim: "·")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            if let zo = pitch.zoPatts {
                Text(verbatim: zo)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .kerning(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.tileFill))
    }

    /// Everything above the senses: header (+ pager/copy), romaji, badges,
    /// pitch pill — never scrolls in the card host. Nested `spacing: 8`
    /// matches the outer VStack so the inline (popover) layout is unchanged.
    private var topSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                headerRow
                if let romaji = DictionaryContent.romaji(for: entry) {
                    Text(romaji)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .textSelection(.disabled)
                }
            }
            badgeRow
            if let pitch = DictionaryContent.pitchPill(for: entry) {
                pitchPill(pitch)
            }
        }
    }

    /// Sense rows inside the host-chosen container: a viewport-clamped
    /// ScrollView for the card, inline for the popover. The zero-spacing
    /// wrapper keeps the height probe live even when the rows are empty.
    @ViewBuilder
    private var sensesSection: some View {
        let measuredRows = VStack(spacing: 0) { senseRows }
            .onHeightChange { onSensesHeightChange($0) }
        if let viewport = sensesViewportHeight {
            ScrollView(.vertical) {
                measuredRows
            }
            .frame(height: max(0, viewport))
            .scrollBounceBehavior(.basedOnSize)
        } else {
            measuredRows
        }
    }

    @ViewBuilder
    private var senseRows: some View {
        let truncated = DictionaryContent.truncatedSenses(entry.senses, limit: senseLimit)
        if !truncated.visible.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(truncated.visible.enumerated()), id: \.offset) { index, sense in
                    senseRow(number: index + 1, sense: sense)
                }
                if truncated.hidden > 0 {
                    Text("+ \(truncated.hidden) more senses")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func senseRow(number: Int, sense: JMDictSense) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
            if let pos = DictionaryContent.posLabel(sense.pos) {
                DictionaryBadgeView(text: pos, color: Theme.accentPink, compact: true)
            }
            let glosses = DictionaryContent.truncatedGlosses(sense.glosses, limit: glossLimit)
            // Visible glosses join into one wrapping line; a hidden tail
            // closes with an ellipsis.
            Text(
                glosses.visible.joined(separator: "; ")
                    + (glosses.hidden > 0 ? "; …" : "")
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.primaryText)
            .textSelection(.disabled)
        }
    }

    /// "also:" pills — always rendered below the senses viewport, never
    /// scrolled. The zero-spacing wrapper keeps the height probe at 0 when
    /// the row is absent (no stale measurement on entry switches).
    private var alsoSection: some View {
        VStack(spacing: 0) {
            alsoRow
        }
        .onHeightChange { onAlsoHeightChange($0) }
    }

    @ViewBuilder
    private var alsoRow: some View {
        let pills = DictionaryContent.truncatedAlso(also)
        if !pills.isEmpty {
            HStack(spacing: 6) {
                Text("also:")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                ForEach(Array(pills.enumerated()), id: \.offset) { _, result in
                    Button {
                        onSelectAlso(result)
                    } label: {
                        Text(verbatim: result.matched)
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.accentPink.opacity(0.16)))
                            .foregroundStyle(Theme.annotationPink)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Look up “\(result.matched)”")
                }
            }
        }
    }
}

/// `◀ i/N ▶` walker over the entries a homograph candidate matched — shared
/// by the popover header row and the sidebar card's DICTIONARY label row.
struct DictionaryEntryPager: View {
    let entryIndex: Int
    let entryCount: Int
    var onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            pagerButton("chevron.left", enabled: entryIndex > 0) {
                onStep(entryIndex - 1)
            }
            Text("\(entryIndex + 1)/\(entryCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            pagerButton("chevron.right", enabled: entryIndex < entryCount - 1) {
                onStep(entryIndex + 1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pagerButton(_ icon: String, enabled: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(enabled ? Theme.primaryText : Theme.secondaryText.opacity(0.4))
                .frame(width: 18, height: 18)
                .background(Theme.tileFill.clipShape(Circle()))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointerStyle(enabled ? .link : nil)
    }
}

/// One badge chip (COMMON, ≈N5, POS): outlined capsule with a tinted fill.
struct DictionaryBadgeView: View {
    let text: String
    let color: Color
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 9 : 10, weight: .semibold))
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                Capsule().fill(color.opacity(0.14))
                    .overlay(Capsule().stroke(color.opacity(0.55)))
            )
            .foregroundStyle(color)
    }
}

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
        VStack(alignment: .leading, spacing: 10) {
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

extension Collection where Index == Int {
    /// The element at `index` when in bounds — popover/card paging reads a
    /// selection that a newer tap may have replaced concurrently.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension View {
    /// Height probe used by the dictionary card's scroll sizing: reports
    /// the view's own height through `onGeometryChange`.
    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: action)
    }
}

// The card chrome (fill + stroke) is declared in SidebarView.swift.
