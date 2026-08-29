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
            guard oldValue != locked, let content = contentView else { return }
            content.needsLayout = true
            content.superview?.layoutSubtreeIfNeeded()
            var frame = self.frame
            frame.size.height += 1
            frame.origin.y -= 1
            setFrame(frame, display: false, animate: false)
            frame.size.height -= 1
            frame.origin.y += 1
            setFrame(frame, display: false, animate: false)
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

    private var panel: HUDPanel? { window as? HUDPanel }

    // Must mirror `padlockButton`'s layout: 24×24 button with 6pt padding,
    // expanded by a 4pt margin for a comfortable hit target.
    private var unlockRegion: CGRect {
        let size: CGFloat = 24
        let pad: CGFloat = 6
        let margin: CGFloat = 4
        return CGRect(
            x: bounds.width - pad - size - margin,
            y: pad - margin,
            width: size + 2 * margin,
            height: size + 2 * margin)
    }

    override func layout() {
        super.layout()
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

struct HUDView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LivePartialState
    @ObservedObject var panel: HUDPanel
    /// Set on offscreen measurement copies: fixes the layout width so the
    /// measured ideal height reflects text wrapped at the real HUD width.
    var fixedWidth: CGFloat?

    var body: some View {
        if let fixedWidth {
            hudContent.frame(width: fixedWidth, alignment: .topLeading)
        } else {
            hudContent
        }
    }

    private var hudContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            liveSection
                .padding(.bottom, 8)
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .padding(.bottom, 8)
            completedSection
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(panel.locked ? 0.08 : 0.35), lineWidth: 1)
        )
        .frame(minWidth: 360, minHeight: 170)
        .overlay(alignment: .topTrailing) { padlockButton }
    }

    // Pinned top-trailing with 6pt padding; HUDHostingView.unlockRegion
    // mirrors this rect so it stays clickable while locked.
    private var padlockButton: some View {
        Button {
            panel.locked.toggle()
        } label: {
            Image(systemName: panel.locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .help(panel.locked ? "Unlock to move/resize (HUD is click-through when locked)" : "Lock (click-through)")
    }

    private var liveSection: some View {
        Group {
            if !live.partial.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(live.partial)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let romaji = RomajiAnnotator.romaji(for: live.partial) {
                        Text(romaji)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Listening…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
    }

    /// Translated entries only; finalized-but-untranslated sentences never
    /// enter the cycle (the view doesn't move until their translation lands).
    private var translatedEntries: [SessionEntry] {
        model.entries.filter { $0.joinedTranslations != nil }
    }

    private var completedSection: some View {
        Group {
            let entries = translatedEntries
            if entries.isEmpty {
                Text("Waiting for the first sentence…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    entryView(displayedEntry(in: entries))
                    historyButtons(entries: entries)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The pinned entry while browsing history; otherwise (nil pin, or a pin
    /// that no longer resolves) the latest translated entry.
    private func displayedEntry(in entries: [SessionEntry]) -> SessionEntry {
        if let pinned = model.hudPinnedIndex,
           let at = entries.firstIndex(where: { $0.sentence.index == pinned }) {
            return entries[at]
        }
        return entries[entries.count - 1]
    }

    private func entryView(_ entry: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(SessionClock.timestamp(entry.sentence.startS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(entry.sentence.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let romaji = RomajiAnnotator.romaji(for: entry.sentence.text) {
                Text(romaji)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let en = entry.joinedTranslations {
                Text(en)
                    .font(.system(size: 13))
                    .foregroundStyle(.teal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Right-side history cycling. Up = newer (disabled at latest, so the
    /// cursor follows new translations); down = older (pins to that exact
    /// sentence, so new translations never move the view).
    private func historyButtons(entries: [SessionEntry]) -> some View {
        let newest = entries[entries.count - 1].sentence.index
        let oldest = entries[0].sentence.index
        let pinned = model.hudPinnedIndex
        let atLatest = pinned == nil || pinned == newest
        let atOldest = entries.count < 2 || pinned == oldest
        return VStack(spacing: 2) {
            historyButton(
                icon: "chevron.up",
                help: "Newer translation",
                disabled: atLatest) {
                cycleHistory(entries: entries, step: 1)
            }
            historyButton(
                icon: "chevron.down",
                help: "Older translation",
                disabled: atOldest) {
                cycleHistory(entries: entries, step: -1)
            }
        }
        .padding(.top, 1)
    }

    /// Steps the pin one translated entry up/down. Stepping onto the newest
    /// entry clears the pin (re-follows latest, re-disabling up).
    private func cycleHistory(entries: [SessionEntry], step: Int) {
        let current = model.hudPinnedIndex ?? entries[entries.count - 1].sentence.index
        guard let at = entries.firstIndex(where: { $0.sentence.index == current }) else {
            return
        }
        let next = at + step
        guard entries.indices.contains(next) else { return }
        model.hudPinnedIndex = next == entries.count - 1 ? nil : entries[next].sentence.index
    }

    private func historyButton(
        icon: String, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(disabled ? .tertiary : .secondary)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}
