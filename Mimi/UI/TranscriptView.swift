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
    @ReadingAnnotationSetting private var readingAnnotation
    @UIScaleSetting private var uiScale
    @State private var pinnedToBottom = true
    @State private var reAnchorScheduled = false
    /// Latest geometry tick, driving the jump buttons' visibility off the
    /// same ticks the pin logic consumes (no extra observers).
    @State private var scrollSnapshot: ScrollSnapshot?

    private static let bottomAnchorID = "transcript-bottom-anchor"
    private static let topAnchorID = "transcript-top-anchor"
    /// Distance from the viewport bottom within which the user counts as
    /// "at the bottom": dragging up past this unpins, scrolling down into
    /// it re-pins. Small by design — the re-anchor chase lands flush, so
    /// no slack is needed to absorb imprecise landings.
    private static let pinTolerance: CGFloat = 8
    /// Distance under which a re-anchored landing counts as flush and the
    /// chase stops.
    private static let settleEpsilon: CGFloat = 2

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
                        scale: uiScale
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
            .overlay(alignment: .bottomTrailing) { jumpButtons(proxy) }
            // The bottom marker row is 1pt tall; without this List enforces
            // a minimum row height that would keep it from sitting flush.
            .environment(\.defaultMinListRowHeight, 1)
            .animation(
                .spring(response: 0.35, dampingFraction: 0.85),
                value: model.entries.count
            )
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                ScrollSnapshot(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height,
                    insetTop: geometry.contentInsets.top,
                    insetBottom: geometry.contentInsets.bottom
                )
            } action: { old, new in
                scrollSnapshot = new
                if new.offsetY > old.offsetY {
                    // The offset moved toward the bottom: our own re-anchor
                    // landing (which can come up short of flush), or the
                    // user paging down.
                    if pinnedToBottom {
                        // Chase the marker until the content sits flush; a
                        // single scrollTo can land short while the insertion
                        // spring or lazy layout is still settling.
                        if new.distanceToBottom > Self.settleEpsilon {
                            reAnchor(proxy)
                        }
                    } else if new.distanceToBottom <= Self.pinTolerance {
                        // The user scrolled down to the bottom: re-engage.
                        pinnedToBottom = true
                        reAnchor(proxy)
                    }
                } else if new.offsetY < old.offsetY {
                    // The offset moved away from the bottom: the user
                    // dragged up (or an overscroll bounce settled back).
                    // Content growth never moves the offset, but it
                    // inflates the distance, so only trust that distance
                    // on ticks where the content and viewport span held
                    // still. On a mixed tick (a translation landing mid-
                    // drag, a bounce settling under lazy relayout) the
                    // decision is deferred: the chase re-anchors a bounce,
                    // and the next still tick re-evaluates from the
                    // accumulated distance.
                    if abs(new.span - old.span) <= Self.settleEpsilon {
                        pinnedToBottom = new.distanceToBottom <= Self.pinTolerance
                    }
                } else if pinnedToBottom {
                    // The offset didn't move but the content or viewport
                    // changed size (row grew, entry appended, window or
                    // live row resized): keep the bottom edge in view
                    // without dropping the pin. Distance here is the
                    // growth itself, so it must never feed the pin
                    // decision.
                    reAnchor(proxy)
                }
            }
            .onChange(of: model.entries) { _, _ in
                // Covers appends and rows growing when a translation lands.
                reAnchor(proxy)
            }
            .onAppear {
                // List has no `.initialOffset` anchor (ScrollView-only);
                // start pinned at the newest sentence.
                reAnchor(proxy)
            }
            .onChange(of: readingAnnotation) { _, _ in
                // Mode toggles resize every row; re-anchor if pinned.
                reAnchor(proxy)
            }
            .onChange(of: uiScale) { _, _ in
                // Scaling resizes every row; re-anchor if pinned.
                reAnchor(proxy)
            }
        }
    }

    /// Scrolls to the bottom marker on the next runloop tick, once the
    /// layout that triggered the call has landed. Coalesces bursts of
    /// geometry ticks into a single scrollTo; if the landing ends up short
    /// of flush, the chase continues from the geometry handler. The pin is
    /// re-checked at execution time so a user drag that slipped in between
    /// still wins.
    private func reAnchor(_ proxy: ScrollViewProxy) {
        guard !reAnchorScheduled else { return }
        reAnchorScheduled = true
        DispatchQueue.main.async {
            reAnchorScheduled = false
            guard pinnedToBottom else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// Scrolls to the top marker immediately (no chase: the pin is off, so
    /// nothing re-fires until the user scrolls back down).
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(Self.topAnchorID, anchor: .top)
        }
    }

    // MARK: - Jump buttons

    /// Down: repin + chase when the user has scrolled away from the bottom.
    /// Up: release the pin and jump to the oldest sentence. Each hides at
    /// its extreme; visibility comes from the pin flag and the same
    /// geometry ticks that drive it.
    private var showDownButton: Bool {
        !pinnedToBottom
    }

    private var showUpButton: Bool {
        guard let snapshot = scrollSnapshot else { return false }
        return snapshot.distanceToTop > Self.pinTolerance
    }

    private func jumpButtons(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 10) {
            jumpButton("chevron.up", visible: showUpButton) {
                pinnedToBottom = false
                scrollToTop(proxy)
            }
            jumpButton("chevron.down", visible: showDownButton) {
                pinnedToBottom = true
                reAnchor(proxy)
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
    }

    /// The scroll values that separate offset movement (the pin is
    /// re-evaluated) from stationary content or viewport growth (the pin
    /// re-anchors).
    private struct ScrollSnapshot: Equatable {
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No transcript yet")
                .font(ScaledFont.title3(uiScale.factor))
                .foregroundStyle(Theme.secondaryText)
            Text("Play any Japanese audio on your Mac (e.g. a livestream in your browser) and press Start.")
                .font(ScaledFont.callout(uiScale.factor))
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
