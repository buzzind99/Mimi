import SwiftUI

/// Stacked transcript rows, newest first, in one virtualized scroll. While
/// the user is at the top, finalizing a sentence pushes older rows down
/// with a spring; scrolled down, the scroll offset is compensated by the
/// inserted row's height so the visible content doesn't move at all.
struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @State private var isAtTop = true
    @State private var scrollPosition = ScrollPosition()
    @State private var pendingInsertCompensation = false

    private struct ScrollSnapshot: Equatable {
        let offset: CGFloat
        let contentHeight: CGFloat
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.entries.isEmpty {
                        emptyState
                    }
                    ForEach(model.entries.reversed()) { entry in
                        TranscriptRow(entry: entry)
                            .id(entry.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                        Divider().opacity(0.15)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .animation(
                    isAtTop ? .spring(response: 0.35, dampingFraction: 0.85) : nil,
                    value: model.entries.count
                )
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geo in
                ScrollSnapshot(offset: geo.contentOffset.y, contentHeight: geo.contentSize.height)
            } action: { old, new in
                isAtTop = new.offset < 1
                guard pendingInsertCompensation, new.contentHeight > old.contentHeight else { return }
                pendingInsertCompensation = false
                scrollPosition.scrollTo(
                    x: 0,
                    y: new.offset + (new.contentHeight - old.contentHeight)
                )
            }
            .onChange(of: model.entries.count) { _, _ in
                if isAtTop {
                    guard let newest = model.entries.last else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(newest.id, anchor: .top)
                    }
                } else {
                    // A row is being inserted above the viewport; grow the
                    // offset by the same amount so content stays visually put.
                    pendingInsertCompensation = true
                }
            }
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
