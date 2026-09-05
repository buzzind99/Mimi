import SwiftUI

/// Toast stack overlay: cards stacked newest first,
/// `move` + `opacity` transitions, yellow/red treatments per class, × only
/// on `.yellowAuto`, action link on persistent cards. Card styling follows
/// the mock6 toast (300pt, corner 14, themed background/border/icon tint).
struct ToastStackView: View {
    var center: ToastCenter

    var body: some View {
        VStack(spacing: 10) {
            ForEach(center.toasts) { toast in
                ToastCard(toast: toast) {
                    center.dismiss(key: toast.key)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: center.toasts)
        .padding(.trailing, 20)
        .padding(.top, 16)
    }
}

/// One toast card: severity icon, bold title, secondary body, optional fix
/// action (persistent cards), optional × (transient `.yellowAuto` only).
private struct ToastCard: View {
    let toast: ToastCenter.Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundStyle(iconTint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(toast.body)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                if let action = toast.action {
                    Button(action.label) {
                        action.handler()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentPink)
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)

            if toast.style == .yellowAuto {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.primaryText.opacity(0.45))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.tileFill))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.toastBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(borderColor)
                )
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        )
    }

    private var isRedClass: Bool {
        toast.style == .redPersistent
    }

    private var iconName: String {
        isRedClass ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private var iconTint: Color {
        isRedClass ? Theme.toastRedIcon : Theme.dotYellow
    }

    private var borderColor: Color {
        isRedClass ? Theme.toastRedBorder : Theme.toastYellowBorder
    }
}
