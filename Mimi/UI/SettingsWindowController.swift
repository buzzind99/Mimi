import AppKit

/// Settings-window detection + dismissal for the sidebar toolbar — a small
/// helper, not a view: SwiftUI owns the Settings scene's window, this only
/// finds and closes it. SwiftUI keeps the closed Settings window cached in
/// `NSApp.windows`, so visibility — not mere existence — decides the toggle.
@MainActor
enum SettingsWindowController {
    /// SwiftUI's Settings scene window identifier prefix.
    private static let windowID = "com_apple_SwiftUI_Settings_window"

    /// Whether a notification object is the SwiftUI Settings window.
    static func isSettingsWindow(_ object: Any?) -> Bool {
        (object as? NSWindow)?.identifier?.rawValue.hasPrefix(windowID) == true
    }

    /// The Settings window while it is open, else nil.
    static func visibleWindow() -> NSWindow? {
        NSApp.windows.first { isSettingsWindow($0) && $0.isVisible }
    }

    /// Closes an already-resolved open Settings window.
    static func close(_ window: NSWindow) {
        window.performClose(nil)
    }
}
