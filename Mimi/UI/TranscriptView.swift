import SwiftUI

/// Chronological transcript, oldest first, newest appended at the bottom.
/// `.defaultScrollAnchor(.bottom)` pins the view to the newest sentence on
/// first appearance; manual tracking keeps that pin alive where the
/// framework's default loses it. Only scroll-offset movement (the user's
/// gesture, or our own re-anchor) may re-evaluate the pin; growth of the
/// content under a stationary offset — a translation landing on any row, a
/// new entry, a viewport resize — re-anchors to the bottom marker while
/// pinned instead, because measuring distance from freshly grown content
/// would read the growth itself and drop the pin exactly when it must act.
/// Re-anchoring re-fires on every geometry tick, so it rides out the
/// insertion spring until the content settles at the bottom.
struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @ReadingAnnotationSetting private var readingAnnotation
    @State private var pinnedToBottom = true

    private static let bottomAnchorID = "transcript-bottom-anchor"
    /// Distance from the viewport bottom within which the view still counts
    /// as "at the bottom" (absorbs divider and animation slack).
    private static let pinnedTolerance: CGFloat = 400

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
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
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
                if new.offsetY != old.offsetY {
                    // The offset actually moved (user gesture, or our own
                    // re-anchor): re-evaluate the pin from where the content
                    // now sits. Our re-anchor lands within tolerance, so the
                    // pin holds; a user drag away drops it.
                    pinnedToBottom = new.distanceToBottom <= Self.pinnedTolerance
                } else if pinnedToBottom {
                    // The offset didn't move but the content or viewport
                    // changed size (row grew, entry appended, window or live
                    // row resized): keep the bottom edge in view without
                    // dropping the pin. Distance here is the growth itself,
                    // so it must never feed the pin decision.
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
    /// layout that triggered the call has landed. The pin is re-checked at
    /// execution time so a user drag that slipped in between still wins.
    private func reAnchor(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if pinnedToBottom {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
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
