import SwiftUI

// The pure content assembly (`DictionaryContent`) lives in
// `DictionaryContent.swift`; this file holds the view types both dictionary
// hosts render through.

/// One row of tappable result pills under a mono label — the entry view's
/// "also:" fallback hits and the not-found view's "related:" suggestions
/// render through the same component so they can never diverge.
struct DictionaryResultPillRow: View {
    let label: String
    let results: [LookupResult]
    var onSelect: (LookupResult) -> Void

    var body: some View {
        let pills = DictionaryContent.truncatedAlso(results)
        if !pills.isEmpty {
            HStack(spacing: 6) {
                Text(verbatim: label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                ForEach(Array(pills.enumerated()), id: \.offset) { _, result in
                    Button {
                        onSelect(result)
                    } label: {
                        Text(verbatim: DictionaryContent.pillLabel(for: result))
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.accentPink.opacity(0.16)))
                            .foregroundStyle(Theme.annotationPink)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Look up “\(DictionaryContent.pillLabel(for: result))”")
                }
            }
        }
    }
}

/// The not-found card and popover content: the tapped surface with a plain
/// "no entry" line — the lookup never promotes a kanji-split fallback to
/// the display result — and the split hits demoted to "related:" pills
/// (tapping one promotes it to the card's primary result).
struct DictionaryNotFoundView: View {
    let surface: String
    let related: [LookupResult]
    var onSelectRelated: (LookupResult) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: surface)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .textSelection(.disabled)
                Text("No dictionary entry")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.disabled)
            }
            DictionaryResultPillRow(
                label: "related:", results: related, onSelect: onSelectRelated
            )
        }
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
    /// The candidate role the display result came from. A join lead shows
    /// the joined-match badge — the compound matched, not the tapped word.
    var displayOrigin: ExpansionOrigin?
    /// Senses rendered (nil = every sense). Both hosts pass nil — long
    /// entries expand in full; the constant default serves tests and any
    /// future capped host.
    var senseLimit: Int? = DictionaryContent.maxSenses
    /// Glosses per sense (nil = every gloss); same host story as `senseLimit`.
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

    private var headwordText: some View {
        Text(verbatim: headword)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
            .textSelection(.disabled)
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Inline reading beside the kanji while the pair fits; when it
            // doesn't, the furigana-style stack moves the reading above the
            // (still truncating) headword instead of eclipsing it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    headwordText
                        .fixedSize(horizontal: true, vertical: false)
                    if let reading {
                        Text(verbatim: reading)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.annotationPink)
                            .lineLimit(1)
                            .textSelection(.disabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                stackedHeadword
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

    /// Furigana-style fallback: the kana reading above the headword, leading
    /// aligned with it, which keeps its own truncation — the reading never
    /// competes for the kanji's line.
    private var stackedHeadword: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let reading {
                Text(verbatim: reading)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.annotationPink)
                    .lineLimit(1)
                    .textSelection(.disabled)
            }
            headwordText
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
            displayOrigin.flatMap(DictionaryContent.joinedMatchBadge(for:)),
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
        let truncated = DictionaryContent.truncated(entry.senses, limit: senseLimit)
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
            let glosses = DictionaryContent.truncated(sense.glosses, limit: glossLimit)
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
            DictionaryResultPillRow(
                label: "also:", results: also, onSelect: onSelectAlso
            )
        }
        .onHeightChange { onAlsoHeightChange($0) }
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
            .fixedSize()
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                Capsule().fill(color.opacity(0.14))
                    .overlay(Capsule().stroke(color.opacity(0.55)))
            )
            .foregroundStyle(color)
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

// The card surface (fill + stroke) is `View.cardSurface` in Theme.swift.
