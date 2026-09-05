import SwiftUI

/// One stacked row: timestamp range header, EN translation (italic),
/// JP sentence with the configured reading annotation. `Equatable` so
/// SwiftUI skips unchanged rows when the transcript re-diffs.
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
        VStack(alignment: .leading, spacing: 4) {
            Text("\(entry.startTimestamp) – \(entry.endTimestamp)")
                .font(ScaledFont.caption(scale.factor).monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.6))

            if let joined = entry.joinedTranslations {
                Text(joined)
                    .font(ScaledFont.body(scale.factor))
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("…")
                    .font(ScaledFont.body(scale.factor))
                    .italic()
                    .foregroundStyle(.secondary.opacity(0.3))
            }

            // RubyTextView renders .none as plain text, so one call covers
            // every annotation mode; selectable in all modes.
            RubyTextView(
                text: entry.sentence.text,
                annotation: annotation,
                surfaceFont: .system(size: 17 * scale.factor, weight: .medium),
                annotationFont: ScaledFont.caption(scale.factor).monospaced(),
                annotationColor: .secondary.opacity(0.55)
            )
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
