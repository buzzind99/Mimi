import SwiftUI

/// Live partial-subtitle row. Isolated so the high-frequency partial state
/// (6–10 Hz) re-renders only this row, never the transcript.
struct LiveSubtitleView: View {
    @ObservedObject var live: LivePartialState
    @ReadingAnnotationSetting private var readingAnnotation
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.teal)
                    .frame(width: 7, height: 7)
                    .opacity(pulsing && !live.partial.isEmpty ? 0.45 : 1)
                    .animation(
                        live.partial.isEmpty
                            ? nil
                            : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: pulsing
                    )
                    .opacity(live.partial.isEmpty ? 0.35 : 1)

                Text("live")
                    .font(.caption.monospaced().bold())
                    .foregroundColor(.teal)
                    .opacity(live.partial.isEmpty ? 0.5 : 1)
            }
            .onChange(of: live.partial.isEmpty) { _, isEmpty in
                guard !isEmpty else { return }
                pulsing = false
                DispatchQueue.main.async { pulsing = true }
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
        .background(Color.teal.opacity(0.12))
    }

    /// The ruby replaces both the partial slot and the romaji slot.
    /// minHeight equals their combined height (22 + 4 + 14) so empty↔filled
    /// transitions don't change the row height.
    private var annotatedPartial: some View {
        Group {
            if live.partial.isEmpty {
                placeholder
            } else {
                RubyTextView(
                    text: live.partial,
                    annotation: readingAnnotation,
                    surfaceFont: .system(size: 17, weight: .medium),
                    annotationFont: .caption.monospaced(),
                    annotationColor: .secondary.opacity(0.55),
                    surfaceItalic: true
                )
                .foregroundColor(.teal)
            }
        }
        .frame(minHeight: 40, alignment: .topLeading)
    }

    @ViewBuilder
    private var plainPartial: some View {
        if live.partial.isEmpty {
            placeholder
                .frame(height: 22, alignment: .leading)
        } else {
            Text(live.partial)
                .font(.system(size: 17, weight: .medium))
                .italic()
                .foregroundColor(.teal)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(height: 22, alignment: .leading)
        }
    }

    private var placeholder: some View {
        Text("…")
            .font(.system(size: 17, weight: .medium))
            .italic()
            .foregroundColor(.secondary.opacity(0.35))
    }
}
