import SwiftUI

/// Chronological transcript, oldest first, newest appended at the bottom.
///
/// Scroll behavior is a thin manual pin. The `ScrollView`-only role-scoped
/// default anchors (`.initialOffset`, `.sizeChanges`) do not apply to `List`
/// — `defaultScrollAnchor` is documented as associating the anchor to a
/// `ScrollView` — so `List` relies entirely on the pin:
///
/// - Starting at the newest sentence is covered by `reAnchor` on appear and
///   on every entries change.
/// - Growth of the content under a stationary offset — a translation landing
///   on any row, a new entry, a viewport resize — re-anchors to the bottom
///   marker while pinned.
///
/// The manual pin is decided by scroll direction: only movement of the
/// offset *away* from the bottom (the user dragging up) can drop it, and
/// scrolling back down into the bottom re-engages it. That decision only
/// reads the distance on ticks where the content and viewport span held
/// still, so a translation landing in the same tick as a drag can't
/// masquerade as either. Distance measured from freshly grown content would
/// read the growth itself and drop the pin exactly when it must act, so
/// growth ticks never feed the pin decision.
/// Re-anchoring then chases the bottom marker on every geometry tick until
/// the content sits flush: a single scrollTo can land short while the
/// insertion spring or List's estimated layout is still settling, so the
/// chase converges quietly.
struct TranscriptView: View {
    var model: AppModel
    @AppStorage(ReadingAnnotation.storageKey) private var readingAnnotation = ReadingAnnotation.romaji
    @AppStorage(CursorMode.storageKey) private var cursorMode = CursorMode.none
    @AppStorage(UIScale.storageKey) private var uiScale = UIScale.default
    /// Scroll state held out of the body: per-tick geometry writes land on
    /// the model, never on this view's graph, so a drag doesn't re-diff
    /// the rows.
    @State private var scroll = TranscriptScrollModel()

    static let bottomAnchorID = "transcript-bottom-anchor"
    static let topAnchorID = "transcript-top-anchor"

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Color.clear
                    .frame(height: 1)
                    .padding(.top, 16)
                    .id(Self.topAnchorID)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if model.entries.isEmpty {
                    emptyState
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(model.entries) { entry in
                    TranscriptRow(
                        entry: entry,
                        annotation: readingAnnotation,
                        scale: uiScale,
                        cursorMode: cursorMode,
                        onCopy: { model.copySnippet($0) },
                        onLookup: {
                            model.handleLookupTap(
                                $0,
                                source: .transcript(
                                    sentenceIndex: entry.sentence.index,
                                    tokenIndex: $0.tokenIndex
                                )
                            )
                        },
                        lookupAnchor: lookupAnchor(for: entry.sentence.index),
                        lookupPopover: { tokenIndex in
                            lookupPopover(entry.sentence.index, tokenIndex)
                        }
                    )
                    // Opacity only: a .move transition animates
                    // relative to the viewport, which displaces
                    // neighboring rows while the re-anchor chase is
                    // also repositioning content.
                    .transition(.opacity)
                    .id(entry.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                Color.clear
                    .frame(height: 1)
                    .padding(.bottom, 12)
                    .id(Self.bottomAnchorID)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Circular jump buttons, stacked bottom-trailing (clears the
            // toast zone at the top-trailing corner where the toast stack
            // mounts).
            .overlay(alignment: .bottomTrailing) {
                TranscriptJumpButtons(scroll: scroll, proxy: proxy)
            }
            // The bottom marker row is 1pt tall; without this List enforces
            // a minimum row height that would keep it from sitting flush.
            .environment(\.defaultMinListRowHeight, 1)
            .animation(
                .spring(response: 0.35, dampingFraction: 0.85),
                value: model.entries.count
            )
            .onScrollGeometryChange(for: TranscriptScrollPin.Snapshot.self) { geometry in
                TranscriptScrollPin.Snapshot(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height,
                    insetTop: geometry.contentInsets.top,
                    insetBottom: geometry.contentInsets.bottom
                )
            } action: { old, new in
                scroll.handle(old: old, new: new, proxy: proxy)
            }
            .onChange(of: model.entries) { _, _ in
                // Covers appends and rows growing when a translation lands.
                scroll.reAnchor(proxy)
            }
            .onAppear {
                // List has no `.initialOffset` anchor (ScrollView-only);
                // start pinned at the newest sentence.
                scroll.reAnchor(proxy)
            }
            .onChange(of: readingAnnotation) { _, _ in
                // Mode toggles resize every row; re-anchor if pinned.
                scroll.reAnchor(proxy)
            }
            .onChange(of: uiScale) { _, _ in
                // Scaling resizes every row; re-anchor if pinned.
                scroll.reAnchor(proxy)
            }
            .onChange(of: cursorMode) { _, _ in
                // Dictionary mode restructures every row's flow children
                // (per-token units, no plain-run folding), changing row
                // heights; re-anchor if pinned.
                scroll.reAnchor(proxy)
            }
        }
    }

    /// Whether this row owns the word-anchored dictionary popover: the
    /// selection's transcript source matching this row's sentenceIndex.
    /// Reading it in the body (not inside a closure) registers the
    /// observation dependency that re-diffs the rows when the selection
    /// lands, moves, or clears.
    private func lookupAnchor(for sentenceIndex: Int) -> SelectedLookup.Source? {
        guard
            case let .transcript(anchorSentenceIndex, _)? = model.selectedLookup?.source,
            anchorSentenceIndex == sentenceIndex
        else { return nil }
        return model.selectedLookup?.source
    }

    /// Per-word popover presentation for the row's word units: the
    /// binding is true only while this exact word is the selection's
    /// anchor (a different-word retap dismisses and re-presents), and the
    /// content is the shared entry view once the async lookup has landed.
    private func lookupPopover(
        _ sentenceIndex: Int, _ tokenIndex: Int
    ) -> RubyTextView.LookupPopover {
        let source = SelectedLookup.Source.transcript(
            sentenceIndex: sentenceIndex, tokenIndex: tokenIndex
        )
        return RubyTextView.LookupPopover(
            isPresented: model.lookupPopoverBinding(for: source),
            content: model.selectedLookup?.popoverItem(for: source).map {
                DictionaryPopoverView(model: model, selected: $0)
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No transcript yet")
                .font(ScaledFont.title3(uiScale.factor))
                .foregroundStyle(Theme.secondaryText)
            Text("Play any Japanese audio on your Mac (e.g. a livestream in your browser) and press Start session.")
                .font(ScaledFont.callout(uiScale.factor))
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// Pure tick→decision core for the transcript's manual bottom pin,
/// separated from the observable scroll state so the pin semantics stay
/// unit-testable without a scroll view. The rules:
///
/// - Only movement of the offset *away* from the bottom (the user dragging
///   up) can drop the pin, and only on ticks where the content and viewport
///   span held still, so a translation landing in the same tick as a drag
///   can't masquerade as either. Distance measured from freshly grown
///   content would read the growth itself and drop the pin exactly when it
///   must act, so growth ticks never feed the pin decision.
/// - While pinned, movement toward the bottom chases the bottom marker
///   until the content sits flush: a single scrollTo can land short while
///   the insertion spring or List's estimated layout is still settling.
/// - Unpinned, movement into the bottom tolerance re-engages the pin.
enum TranscriptScrollPin {
    /// Distance from the viewport bottom within which the user counts as
    /// "at the bottom": dragging up past this unpins, scrolling down into
    /// it re-pins. Small by design — the re-anchor chase lands flush, so
    /// no slack is needed to absorb imprecise landings.
    static let pinTolerance: CGFloat = 8
    /// Distance under which a re-anchored landing counts as flush and the
    /// chase stops; also the span delta under which a tick counts as
    /// "still" for the pin decision.
    static let settleEpsilon: CGFloat = 2

    /// The scroll values that separate offset movement (the pin is
    /// re-evaluated) from stationary content or viewport growth (the pin
    /// re-anchors).
    struct Snapshot: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var insetTop: CGFloat
        var insetBottom: CGFloat

        var distanceToBottom: CGFloat {
            contentHeight + insetBottom - (offsetY + containerHeight)
        }

        /// Distance from the viewport top to the content top; zero when
        /// scrolled flush to the oldest sentence.
        var distanceToTop: CGFloat {
            offsetY + insetTop
        }

        /// Everything that changes `distanceToBottom` except the offset:
        /// content height, content insets, viewport size. A tick where the
        /// span moved is growth or relayout, and its distance is not a
        /// trustworthy pin signal.
        var span: CGFloat {
            contentHeight + insetBottom - containerHeight
        }
    }

    /// What one geometry tick asks the scroll owner to do: whether to
    /// re-anchor to the bottom marker, and what the pin flag becomes.
    struct Tick: Equatable {
        var reanchors: Bool
        var pinnedAfter: Bool
    }

    /// Maps one geometry tick onto the pin rules; `pinned` is the flag
    /// before the tick.
    static func tick(old: Snapshot, new: Snapshot, pinned: Bool) -> Tick {
        if new.offsetY > old.offsetY {
            // The offset moved toward the bottom: our own re-anchor
            // landing (which can come up short of flush), or the user
            // paging down.
            if pinned {
                // Chase the marker until the content sits flush.
                return Tick(
                    reanchors: new.distanceToBottom > settleEpsilon, pinnedAfter: pinned
                )
            }
            // The user scrolled down to the bottom: re-engage.
            if new.distanceToBottom <= pinTolerance {
                return Tick(reanchors: true, pinnedAfter: true)
            }
            return Tick(reanchors: false, pinnedAfter: pinned)
        }
        if new.offsetY < old.offsetY {
            // The offset moved away from the bottom: the user dragged up
            // (or an overscroll bounce settled back). Content growth never
            // moves the offset, but it inflates the distance, so only
            // trust that distance on ticks where the span held still. On a
            // mixed tick (a translation landing mid-drag, a bounce
            // settling under lazy relayout) the decision is deferred: the
            // chase re-anchors a bounce, and the next still tick
            // re-evaluates from the accumulated distance.
            guard abs(new.span - old.span) <= settleEpsilon else {
                return Tick(reanchors: false, pinnedAfter: pinned)
            }
            return Tick(
                reanchors: false,
                pinnedAfter: new.distanceToBottom <= pinTolerance
            )
        }
        // The offset didn't move but the content or viewport changed size
        // (row grew, entry appended, window or live row resized): keep the
        // bottom edge in view without dropping the pin. Distance here is
        // the growth itself, so it must never feed the pin decision.
        return Tick(reanchors: pinned, pinnedAfter: pinned)
    }

    /// Jump-button visibility off the same signals the pin consumes: the
    /// down button tracks the pin flag, the up button the distance from
    /// the content top. Before the first tick lands (`nil` snapshot) both
    /// hide.
    static func visibility(
        pinned: Bool, snapshot: Snapshot?
    ) -> (up: Bool, down: Bool) {
        (
            up: snapshot.map { $0.distanceToTop > pinTolerance } ?? false,
            down: !pinned
        )
    }
}

/// Scroll-side state for the transcript's manual bottom pin, held out of
/// `TranscriptView` so per-tick geometry writes never invalidate the
/// row-diffing body: the raw snapshot, pin flag, and coalescing flag are
/// written every tick but read only inside these handlers — no body
/// observes them — while the jump buttons observe just the two visibility
/// flags, which are assigned only on an actual flip.
@Observable
@MainActor
private final class TranscriptScrollModel {
    private var snapshot: TranscriptScrollPin.Snapshot?
    private var pinnedToBottom = true
    /// Coalesces bursts of re-anchor requests into a single scrollTo.
    private var reAnchorScheduled = false

    private(set) var showUpButton = false
    private(set) var showDownButton = false

    /// Consumes one geometry tick: re-evaluates the pin decision, refreshes
    /// jump-button visibility, and chases the bottom marker as decided. A
    /// tick that flips nothing and re-anchors nowhere touches no observed
    /// property, so it renders nothing.
    func handle(
        old: TranscriptScrollPin.Snapshot,
        new: TranscriptScrollPin.Snapshot,
        proxy: ScrollViewProxy
    ) {
        snapshot = new
        let tick = TranscriptScrollPin.tick(old: old, new: new, pinned: pinnedToBottom)
        pinnedToBottom = tick.pinnedAfter
        refreshVisibility()
        if tick.reanchors {
            reAnchor(proxy)
        }
    }

    /// Up button: release the pin and jump to the oldest sentence (no
    /// chase: the pin is off, so nothing re-fires until the user scrolls
    /// back down).
    func unpinAndScrollToTop(_ proxy: ScrollViewProxy) {
        pinnedToBottom = false
        refreshVisibility()
        scrollToTop(proxy)
    }

    /// Down button: re-engage the pin and chase the bottom marker.
    func repinAndChase(_ proxy: ScrollViewProxy) {
        pinnedToBottom = true
        refreshVisibility()
        reAnchor(proxy)
    }

    /// Scrolls to the bottom marker on the next runloop tick, once the
    /// layout that triggered the call has landed. Coalesces bursts of
    /// geometry ticks into a single scrollTo; if the landing ends up short
    /// of flush, the chase continues from the geometry handler. The pin is
    /// re-checked at execution time so a user drag that slipped in between
    /// still wins.
    func reAnchor(_ proxy: ScrollViewProxy) {
        guard !reAnchorScheduled else { return }
        reAnchorScheduled = true
        DispatchQueue.main.async { @MainActor [self] in
            reAnchorScheduled = false
            guard pinnedToBottom else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(TranscriptView.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(TranscriptView.topAnchorID, anchor: .top)
        }
    }

    private func refreshVisibility() {
        let next = TranscriptScrollPin.visibility(pinned: pinnedToBottom, snapshot: snapshot)
        if showUpButton != next.up {
            showUpButton = next.up
        }
        if showDownButton != next.down {
            showDownButton = next.down
        }
    }
}

/// The transcript's jump buttons — the only per-scroll-tick UI. Observes
/// just the scroll model's two visibility flags, so the vast majority of
/// geometry ticks (plain drags, the re-anchor chase, pin churn) render
/// nothing at all.
private struct TranscriptJumpButtons: View {
    let scroll: TranscriptScrollModel
    let proxy: ScrollViewProxy

    var body: some View {
        VStack(spacing: 10) {
            jumpButton("chevron.up", visible: scroll.showUpButton) {
                scroll.unpinAndScrollToTop(proxy)
            }
            jumpButton("chevron.down", visible: scroll.showDownButton) {
                scroll.repinAndChase(proxy)
            }
        }
        .padding(.trailing, 24)
        .padding(.bottom, 20)
    }

    private func jumpButton(
        _ systemImage: String,
        visible: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.annotationPink)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Theme.jumpButtonBackground)
                        .overlay(Circle().stroke(Theme.jumpButtonStroke))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.18), value: visible)
        .pointerStyle(visible ? .link : nil)
    }
}
