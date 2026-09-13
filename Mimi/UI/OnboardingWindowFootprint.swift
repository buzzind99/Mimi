import AppKit
import SwiftUI

extension View {
    /// Shrinks the hosting window to the compact onboarding footprint while
    /// `isOnboarding` holds, and restores the pre-onboarding size afterwards.
    /// The content's conditional min size only moves the resize limits — the
    /// frame itself needs this explicit application.
    func onboardingWindowFootprint(_ isOnboarding: Bool) -> some View {
        background(WindowFootprintHost(isOnboarding: isOnboarding))
    }
}

/// Bridge hosting the footprint view inside the window it resizes.
private struct WindowFootprintHost: NSViewRepresentable {
    let isOnboarding: Bool

    func makeNSView(context: Context) -> WindowFootprintView {
        WindowFootprintView()
    }

    func updateNSView(_ view: WindowFootprintView, context: Context) {
        view.apply(isOnboarding: isOnboarding)
    }
}

/// Applies the onboarding / main window footprints. The desired state
/// survives the attach race (the first `updateNSView` can precede
/// `viewDidMoveToWindow`), and applications are idempotent across repeat
/// updates.
private final class WindowFootprintView: NSView {
    /// Compact footprint while onboarding owns the window.
    private static let onboardingContentSize = NSSize(width: 580, height: 740)

    private var desiredOnboarding = false
    private var appliedOnboarding: Bool?
    private var savedContentSize: NSSize?

    func apply(isOnboarding: Bool) {
        desiredOnboarding = isOnboarding
        applyNow()
    }

    override func viewDidMoveToWindow() {
        applyNow()
    }

    private func applyNow() {
        guard let window, appliedOnboarding != desiredOnboarding else { return }
        appliedOnboarding = desiredOnboarding
        if desiredOnboarding {
            let current = window.contentView?.frame.size ?? window.frame.size
            if current != Self.onboardingContentSize {
                savedContentSize = current
            }
            window.setContentSize(Self.onboardingContentSize)
        } else if let saved = savedContentSize {
            window.setContentSize(saved)
            savedContentSize = nil
        }
        // Centering on both transitions keeps the growing window on-screen
        // (expanding from a centered frame would otherwise overflow edges).
        window.center()
    }
}
