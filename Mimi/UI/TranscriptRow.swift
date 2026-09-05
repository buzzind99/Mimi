import SwiftUI

/// One Sakura Studio row: mono start timestamp in a fixed-width gutter,
/// JP sentence with the configured reading annotation, and the EN
/// translation marked by a gradient capsule bar. `Equatable` so SwiftUI
/// skips unchanged rows when the transcript re-diffs.
struct TranscriptRow: View, Equatable {
    let entry: SessionEntry
    /// Snapshots, not settings: under List, rows SwiftUI deems unchanged are
    /// skipped via `==`, and `@AppStorage`-backed wrappers read the *live*
    /// stored value — so comparing wrapper values would always hold and stale
    /// rows would keep rendering the previous mode. Plain values passed from
    /// the parent let a mode/scale change fail `==` and re-render every row.
    let annotation: ReadingAnnotation
    let scale: UIScale

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(entry.startTimestamp)
                .font(.system(size: 11 * scale.factor, design: .monospaced))
                .foregroundStyle(Theme.gutterText)
                .frame(width: 40 * scale.factor, alignment: .trailing)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 5) {
                // RubyTextView renders .none as plain text, so one call
                // covers every annotation mode; selectable in all modes.
                RubyTextView(
                    text: entry.sentence.text,
                    annotation: annotation,
                    surfaceFont: .system(size: 22 * scale.factor),
                    annotationFont: .system(size: 11 * scale.factor, design: .monospaced),
                    furiganaFont: .system(size: 14 * scale.factor, design: .monospaced),
                    annotationColor: Theme.annotationPink
                )
                .textSelection(.enabled)

                translationRow
            }

            Spacer(minLength: 0)
        }
        // The mock's generous row spacing stands in for the old divider.
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var translationRow: some View {
        if let joined = entry.joinedTranslations {
            // The bar overlays the text's leading edge so it stretches to the
            // full height of the (possibly multi-line) translation.
            Text(joined)
                .font(.system(size: 13 * scale.factor))
                .foregroundStyle(Theme.translationTeal)
                .textSelection(.enabled)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Gradients.translationBar)
                        .frame(width: 3)
                        .offset(x: -11)
                }
        } else {
            Text("…")
                .font(.system(size: 13 * scale.factor))
                .italic()
                .foregroundStyle(Theme.secondaryText.opacity(0.6))
                // Indent past the 3pt bar + 8pt gap so the placeholder lines
                // up with where the translation will land.
                .padding(.leading, 11)
        }
    }
}
