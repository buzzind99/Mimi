import SwiftUI

/// Shared model-download byte formatting: the memory-style byte counts
/// (`byteCount(style: .memory)`) quoted by the settings model row and the
/// onboarding progress copy.
enum ModelDownloadFormat {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .memory))
    }

    /// "downloaded / total" while the total is known, "downloaded" alone
    /// otherwise.
    static func progress(bytes: Int64, total: Int64?) -> String {
        guard let total else { return Self.bytes(bytes) }
        return Self.bytes(bytes) + " / " + Self.bytes(total)
    }
}

/// Download-progress presentation shared by the settings model row footer
/// and onboarding. With a known total: a determinate bar over the byte
/// label. Without: an indeterminate spinner — bare and mini when no
/// `prefix` is set (the compact settings footer), tinted with the byte
/// label otherwise (onboarding's progress line). Surface styling (tint,
/// type, alignment, spacing, leading copy) is parameterized per host. A
/// `total` of 0 counts as unknown — the determinate bar can't use it.
struct ModelDownloadProgressView: View {
    let bytes: Int64
    let total: Int64?
    var tint: Color = Palette.accent
    var font: Font = .system(size: 10.5, design: .monospaced)
    var textColor: Color = Palette.secondaryText
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 5
    /// Copy prepended to the byte counts ("Downloading Lite model… "); nil
    /// also hides the label in the indeterminate branch.
    var prefix: String?

    var body: some View {
        let knownTotal: Int64? = (total ?? 0) > 0 ? total : nil
        VStack(alignment: alignment, spacing: spacing) {
            if let knownTotal {
                ProgressView(value: Double(bytes), total: Double(knownTotal))
                    .tint(tint)
                Text((prefix ?? "") + ModelDownloadFormat.progress(bytes: bytes, total: knownTotal))
                    .font(font)
                    .foregroundStyle(textColor)
            } else {
                ProgressView()
                    .controlSize(prefix == nil ? .mini : .regular)
                    .tint(tint)
                if let prefix {
                    Text(prefix + ModelDownloadFormat.progress(bytes: bytes, total: knownTotal))
                        .font(font)
                        .foregroundStyle(textColor)
                }
            }
        }
    }
}
