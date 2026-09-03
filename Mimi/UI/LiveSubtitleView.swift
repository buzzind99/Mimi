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

    /// All annotation modes hold the same total slot height — surface 22 +
    /// spacing 4 + annotation 14 = 40 — so empty↔filled transitions and
    /// None↔Romaji↔Furigana toggles never change the row height (which would
    /// resize the transcript viewport above).
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
                    surfaceItalic: true,
                    reservesAnnotationLine: true
                )
                .foregroundStyle(.teal)
            }
        }
        .frame(minHeight: 40, alignment: .topLeading)
    }

    /// None mode: surface only, top-aligned to match the romaji surface
    /// position, in the same 40pt slot.
    @ViewBuilder
    private var plainPartial: some View {
        if live.partial.isEmpty {
            placeholder
                .frame(height: 40, alignment: .topLeading)
        } else {
            Text(live.partial)
                .font(.system(size: 17, weight: .medium))
                .italic()
                .foregroundStyle(.teal)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(height: 40, alignment: .topLeading)
        }
    }

    private var placeholder: some View {
        Text("…")
            .font(.system(size: 17, weight: .medium))
            .italic()
            .foregroundStyle(.secondary.opacity(0.35))
    }
}
