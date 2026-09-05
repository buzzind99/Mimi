import SwiftUI

/// Sakura Studio live strip: LIVE indicator + the in-flight partial,
/// pinned below the transcript in the main window. Isolated so the
/// high-frequency partial state (6–10 Hz) re-renders only this view,
/// never the transcript.
struct LiveStripView: View {
    var live: LivePartialState
    @ReadingAnnotationSetting private var readingAnnotation
    @UIScaleSetting private var uiScale
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.liveRed)
                    .frame(width: 9, height: 9)
                    .animation(
                        live.partial.isEmpty
                            ? nil
                            : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: pulsing
                    )
                    .opacity(live.partial.isEmpty ? 0.35 : (pulsing ? 0.45 : 1))

                Text("LIVE")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1.5)
                    .foregroundStyle(Theme.liveRed)
                    .opacity(live.partial.isEmpty ? 0.5 : 1)
            }
            .onChange(of: live.partial.isEmpty) { _, isEmpty in
                guard !isEmpty else { return }
                pulsing = false
                Task { @MainActor in pulsing = true }
            }

            partialSlot
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Theme.liveStrip)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    /// Slot = annotation 13 + surface 22 + annotation 13, sized to the
    /// tallest mode (romaji: reserved line above + surface + romaji
    /// below); every component scales with the UI scale, so the slot does
    /// too. Holding the slot height keeps mode toggles and empty↔filled
    /// transitions from resizing the transcript viewport above.
    private var slotHeight: CGFloat {
        58 * uiScale.factor
    }

    private var partialSlot: some View {
        Group {
            if live.partial.isEmpty {
                placeholderAtSurface
            } else {
                // reservesAnnotationLine pins the surface to the same
                // vertical position across None/Romaji/Furigana toggles.
                RubyTextView(
                    text: live.partial,
                    annotation: readingAnnotation,
                    surfaceFont: .system(size: 22 * uiScale.factor, weight: .medium),
                    annotationFont: .system(size: 13 * uiScale.factor, design: .monospaced),
                    annotationColor: Theme.annotationPink,
                    reservesAnnotationLine: true
                )
                .foregroundStyle(Theme.primaryText.opacity(0.9))
            }
        }
        .frame(minHeight: slotHeight, alignment: .topLeading)
    }

    private var reservedAnnotationLine: some View {
        Text(verbatim: " ")
            .font(.system(size: 13 * uiScale.factor, design: .monospaced))
            .lineLimit(1)
    }

    /// Empty state: the "…" sits where the surface would, keeping the
    /// slot's vertical rhythm.
    private var placeholderAtSurface: some View {
        VStack(spacing: 0) {
            reservedAnnotationLine
            Text("…")
                .font(.system(size: 22 * uiScale.factor, weight: .medium))
                .foregroundStyle(Theme.secondaryText.opacity(0.5))
        }
    }
}
