import SwiftUI

/// Live partial-subtitle row. Isolated so the high-frequency partial state
/// (6–10 Hz) re-renders only this row, never the transcript.
struct LiveSubtitleView: View {
    var live: LivePartialState
    @ReadingAnnotationSetting private var readingAnnotation
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.teal)
                    .frame(width: 7, height: 7)
                    .animation(
                        live.partial.isEmpty
                            ? nil
                            : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: pulsing
                    )
                    .opacity(live.partial.isEmpty ? 0.35 : (pulsing ? 0.45 : 1))

                Text("live")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.teal)
                    .opacity(live.partial.isEmpty ? 0.5 : 1)
            }
            .onChange(of: live.partial.isEmpty) { _, isEmpty in
                guard !isEmpty else { return }
                pulsing = false
                Task { @MainActor in pulsing = true }
            }

            if readingAnnotation != .none {
                annotatedPartial
            } else {
                plainPartial
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.teal.opacity(0.12))
    }

    /// Every mode reserves the annotation line above the surface (visible
    /// furigana, invisible in romaji/none), so the kanji sits at one vertical
    /// position across None↔Romaji↔Furigana toggles and empty↔filled
    /// transitions. Slot = annotation 14 + surface 22 + annotation 14 = 50,
    /// sized to the tallest mode (romaji: line above + surface + romaji).
    private static let slotHeight: CGFloat = 50

    /// All annotation modes hold the same total slot height so mode toggles
    /// never change the row height (which would resize the transcript
    /// viewport above).
    private var annotatedPartial: some View {
        Group {
            if live.partial.isEmpty {
                placeholderAtSurface
            } else {
                RubyTextView(
                    text: live.partial,
                    annotation: readingAnnotation,
                    surfaceFont: .system(size: 17, weight: .medium),
                    annotationFont: .caption.monospaced(),
                    annotationColor: .secondary.opacity(0.55),
                    surfaceItalic: true,
                    reservesAnnotationLine: true
                )
                .foregroundStyle(.teal)
            }
        }
        .frame(minHeight: Self.slotHeight, alignment: .topLeading)
    }

    /// None mode: surface only, at the same reserved-line offset as the
    /// annotated modes, in the same slot.
    @ViewBuilder
    private var plainPartial: some View {
        if live.partial.isEmpty {
            placeholderAtSurface
                .frame(height: Self.slotHeight, alignment: .topLeading)
        } else {
            VStack(spacing: 0) {
                reservedAnnotationLine
                Text(live.partial)
                    .font(.system(size: 17, weight: .medium))
                    .italic()
                    .foregroundStyle(.teal)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(height: Self.slotHeight, alignment: .topLeading)
        }
    }

    private var reservedAnnotationLine: some View {
        Text(verbatim: " ")
            .font(.caption.monospaced())
            .lineLimit(1)
    }

    private var placeholderAtSurface: some View {
        VStack(spacing: 0) {
            reservedAnnotationLine
            placeholder
        }
    }

    private var placeholder: some View {
        Text("…")
            .font(.system(size: 17, weight: .medium))
            .italic()
            .foregroundStyle(.secondary.opacity(0.35))
    }
}
