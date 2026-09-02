import SwiftUI

/// One stacked row: timestamp range header, EN translation (italic),
/// JP sentence with the configured reading annotation. `Equatable` so
/// SwiftUI skips unchanged rows when the transcript re-diffs.
struct TranscriptRow: View, Equatable {
    let entry: SessionEntry
    @ReadingAnnotationSetting private var readingAnnotation

    /// Ignores `readingAnnotation` on purpose: that value lives in
    /// `@AppStorage` via `ReadingAnnotationSetting` (a `DynamicProperty`),
    /// which invalidates this view directly when it changes, bypassing the
    /// Equatable skip — so comparing entries alone is sufficient.
    static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.entry == rhs.entry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(entry.startTimestamp) – \(entry.endTimestamp)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.6))

            if let joined = entry.joinedTranslations {
                Text(joined)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("…")
                    .italic()
                    .foregroundStyle(.secondary.opacity(0.3))
            }

            // RubyTextView renders .none as plain text, so one call covers
            // every annotation mode; selectable in all modes.
            RubyTextView(
                text: entry.sentence.text,
                annotation: readingAnnotation,
                surfaceFont: .system(size: 17, weight: .medium),
                annotationFont: .caption.monospaced(),
                annotationColor: .secondary.opacity(0.55)
            )
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
