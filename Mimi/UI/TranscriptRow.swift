import SwiftUI

/// One stacked row: timestamp range header, EN translation (italic),
/// JP sentence with the configured reading annotation. `Equatable` so
/// SwiftUI skips unchanged rows when the transcript re-diffs.
struct TranscriptRow: View, Equatable {
    let entry: SessionEntry
    @ReadingAnnotationSetting private var readingAnnotation

    static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.entry == rhs.entry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(entry.startTimestamp) – \(entry.endTimestamp)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary.opacity(0.6))

            if let joined = entry.joinedTranslations {
                Text(joined)
                    .italic()
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("…")
                    .italic()
                    .foregroundColor(.secondary.opacity(0.3))
            }

            if readingAnnotation != .none {
                RubyTextView(
                    text: entry.sentence.text,
                    annotation: readingAnnotation,
                    surfaceFont: .system(size: 17, weight: .medium),
                    annotationFont: .caption.monospaced(),
                    annotationColor: .secondary.opacity(0.55)
                )
            } else {
                Text(entry.sentence.text)
                    .font(.system(size: 17, weight: .medium))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
