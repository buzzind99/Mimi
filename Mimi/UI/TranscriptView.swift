import SwiftUI

/// Chronological transcript, oldest first, newest appended at the bottom.
/// `.defaultScrollAnchor(.bottom)` pins the view to the newest sentence on
/// first appearance; manual tracking keeps that pin alive where the
/// framework's default loses it.
///
/// The pin is decided by scroll direction: only movement of the offset
/// *away* from the bottom (the user dragging up) can drop it, and scrolling
/// back down into the bottom re-engages it. That decision only reads the
/// distance on ticks where the content and viewport span held still, so a
/// translation landing in the same tick as a drag or a bounce can't
/// masquerade as either. Growth of the content under a
/// stationary offset — a translation landing on any row, a new entry, a
/// viewport resize — re-anchors to the bottom marker while pinned instead,
/// because measuring distance from freshly grown content would read the
/// growth itself and drop the pin exactly when it must act. Re-anchoring
/// then chases the bottom marker on every geometry tick until the content
/// sits flush: a single scrollTo can land short while the insertion spring
/// or the LazyVStack's estimated layout is still settling.
struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @ReadingAnnotationSetting private var readingAnnotation
    @State private var pinnedToBottom = true
    @State private var reAnchorScheduled = false

    private static let bottomAnchorID = "transcript-bottom-anchor"
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.entries.isEmpty {
                        emptyState
                    }
                    ForEach(model.entries) { entry in
                        TranscriptRow(entry: entry)
                            .id(entry.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        Divider().opacity(0.15)
                    }
                    Color.clear
                        .frame(height: 1)
                        .padding(.bottom, 12)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 16)
                .animation(
                    .spring(response: 0.35, dampingFraction: 0.85),
                    value: model.entries.count
                )
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                ScrollSnapshot(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height,
                    insetBottom: geometry.contentInsets.bottom
                )
            } action: { old, new in
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
            .onChange(of: readingAnnotation) { _, _ in
                // Mode toggles resize every row; re-anchor if pinned.
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
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// The scroll values that separate offset movement (the pin is
    /// re-evaluated) from stationary content or viewport growth (the pin
    /// re-anchors).
    private struct ScrollSnapshot: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var insetBottom: CGFloat

        var distanceToBottom: CGFloat {
            contentHeight + insetBottom - (offsetY + containerHeight)
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
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Play any Japanese audio on your Mac (e.g. a livestream in your browser) and press Start.")
                .font(.callout)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
