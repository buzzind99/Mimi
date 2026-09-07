import SwiftUI

/// Transient notice pill (e.g. "Text copied"): minimal hug-content capsule,
/// solid teal fill with contrasting text, no icon or dismiss button. Slides
/// in from the top like the toast stack; auto-dismisses via `NoticeCenter`.
struct NoticePillView: View {
    var center: NoticeCenter

    var body: some View {
        VStack {
            if let message = center.message {
                Text(message)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.noticeText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.noticeFill)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: center.message)
        .padding(.top, 12)
        .allowsHitTesting(false)
    }
}
