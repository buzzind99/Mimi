import SwiftUI

/// Transient notice pill (e.g. "Text copied"): minimal hug-content capsule,
/// solid fill with contrasting text per tone (teal confirm, amber warning),
/// no icon or dismiss button. Slides in from the top like the toast stack;
/// auto-dismisses via `NoticeCenter`.
struct NoticePillView: View {
    var center: NoticeCenter

    var body: some View {
        VStack {
            if let message = center.message {
                let tokens = Theme.noticeTokens(for: center.tone)
                Text(message)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tokens.fill)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: center.message)
        .padding(.top, 12)
        .allowsHitTesting(false)
    }
}
