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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
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
            NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 90)
        )
        installContent(in: panel)
        self.panel = panel
        return panel
    }

    private func installContent(in panel: HUDPanel) {
        guard let model, let live else { return }
        let hosting = HUDHostingView(rootView: HUDView(model: model, live: live, panel: panel))
        hosting.makeMeasureRoot = { width in
            HUDView(model: model, live: live, panel: panel, fixedWidth: width)
        }
        panel.contentView = hosting
    }
}

/// Non-activating panel that owns the HUD lock state (click-through vs
/// interactive). Click-through is enforced by `HUDHostingView.hitTest`,
/// not by `ignoresMouseEvents`, so the padlock stays clickable.
final class HUDPanel: NSPanel, ObservableObject {
    @Published var locked = true {
        didSet {
            guard oldValue != locked, let content = contentView as? HUDHostingView else { return }
            content.needsLayout = true
            content.refitHeight()
        }
    }
}

/// Hosts the HUD content and implements click-through via hit-testing:
/// while locked, only the padlock's region accepts mouse events; every
/// other point returns nil so clicks land on the window underneath.
/// Also grows the window vertically to fit its content (top edge anchored).
final class HUDHostingView: NSHostingView<HUDView> {
    /// Builds a fixed-width measurement copy of the HUD content so the
    /// fully-wrapped ideal height can be computed offscreen.
    var makeMeasureRoot: ((CGFloat) -> HUDView)?

    private var measureHost: NSHostingView<HUDView>?

    private var panel: HUDPanel? {
        window as? HUDPanel
    }

    /// Must mirror `padlockButton`'s layout: 24×24 button with 6pt padding,
    /// expanded by a 4pt margin for a comfortable hit target.
    private var unlockRegion: CGRect {
        let size: CGFloat = 24
        let pad: CGFloat = 6
        let margin: CGFloat = 4
        return CGRect(
            x: bounds.width - pad - size - margin,
            y: pad - margin,
            width: size + 2 * margin,
            height: size + 2 * margin
        )
    }

    override func layout() {
        super.layout()
        fitWindowHeight()
    }

    /// Re-fits the window height to the content; exposed for
    /// `HUDPanel.locked` didSet, where unlocking changes the border and may
    /// change the wrapped ideal height.
    func refitHeight() {
        fitWindowHeight()
    }

    private func fitWindowHeight() {
        guard let makeMeasureRoot, let panel else { return }
        let width = bounds.width
        if let measureHost {
            if measureHost.rootView.fixedWidth != width {
                measureHost.rootView = makeMeasureRoot(width)
            }
        } else {
            measureHost = NSHostingView(rootView: makeMeasureRoot(width))
        }
        guard let measureHost else { return }
        var ideal = measureHost.fittingSize.height
        if let screenHeight = panel.screen?.visibleFrame.height {
            ideal = min(ideal, screenHeight)
        }
        guard abs(panel.frame.height - ideal) > 1 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = ideal
        frame.origin.y = top - ideal
        panel.setFrame(frame, display: true, animate: false)
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
