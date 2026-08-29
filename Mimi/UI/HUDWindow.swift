import AppKit
import SwiftUI

/// Floating HUD window: always-on-top semi-transparent subtitle overlay.
/// Click-through when locked; unlock (padlock button) to move/resize.
final class HUDWindowController {
    static let shared = HUDWindowController()

    private var panel: HUDPanel?
    private var model: AppModel?
    private var live: LivePartialState?

    private init() {}

    func bind(model: AppModel, live: LivePartialState) {
        self.model = model
        self.live = live
        if let panel {
            installContent(in: panel)
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel: HUDPanel = self.panel ?? makePanel()
        panel.orderFrontRegardless()
    }

    // MARK: - Panel

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 150),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.center()

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(
            NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 90))
        installContent(in: panel)
        self.panel = panel
        return panel
    }

    private func installContent(in panel: HUDPanel) {
        guard let model, let live else { return }
        let root = HUDView(model: model, live: live, panel: panel)
        panel.contentView = HUDHostingView(rootView: root)
    }
}

/// Non-activating panel that owns the HUD lock state (click-through vs
/// interactive). Click-through is enforced by `HUDHostingView.hitTest`,
/// not by `ignoresMouseEvents`, so the padlock stays clickable.
final class HUDPanel: NSPanel, ObservableObject {
    @Published var locked = true
}

/// Hosts the HUD content and implements click-through via hit-testing:
/// while locked, only the padlock's region accepts mouse events; every
/// other point returns nil so clicks land on the window underneath.
final class HUDHostingView: NSHostingView<HUDView> {
    private var panel: HUDPanel? { window as? HUDPanel }

    // Covers the padlock button in the top-right corner (12pt content padding).
    private var unlockRegion: CGRect {
        let size: CGFloat = 24
        let pad: CGFloat = 12
        let margin: CGFloat = 4
        return CGRect(
            x: bounds.width - pad - size - margin,
            y: pad - margin,
            width: size + 2 * margin,
            height: size + 2 * margin)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let panel, panel.locked else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return unlockRegion.contains(local) ? super.hitTest(point) : nil
    }

    override var mouseDownCanMoveWindow: Bool {
        guard let panel else { return super.mouseDownCanMoveWindow }
        return !panel.locked
    }
}

struct HUDView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LivePartialState
    @ObservedObject var panel: HUDPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button {
                    panel.locked.toggle()
                } label: {
                    Image(systemName: panel.locked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(panel.locked ? "Unlock to move/resize (HUD becomes click-through when locked)" : "Lock (click-through)")
            }

            if !live.partial.isEmpty {
                Text(live.partial)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            } else if let lastJP = live.lastFinalJP {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(SessionClock.timestamp(lastJP.startS))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(lastJP.text)
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                    }
                    if let romaji = RomajiAnnotator.romaji(for: lastJP.text) {
                        Text(romaji)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                }
            } else {
                Text("Mimi HUD")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            if !live.lastFinalEN.isEmpty {
                Text(live.lastFinalEN)
                    .font(.system(size: 14))
                    .foregroundStyle(.teal)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(panel.locked ? 0.08 : 0.35), lineWidth: 1)
        )
        .frame(minWidth: 320, minHeight: 110)
    }
}
