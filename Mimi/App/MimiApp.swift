import AppKit
import SwiftUI

@main
struct MimiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mimi") {
            ContentView(model: model, live: model.live, latency: model.latency)
                .onChange(of: model.hudVisible) { _, visible in
                    if visible {
                        appDelegate.hud.bind(model: model, live: model.live)
                    }
                    appDelegate.hud.setVisible(visible)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Copy Transcript") {
                    model.copyTranscript()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.isExportable)
            }
        }

        Settings {
            SettingsView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// Bridges AppKit (HUD panel) and the quit-time teardown handshake.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let hud = HUDWindowController.shared

    /// Upper bound on quit-time teardown: whichever arrives first — the
    /// teardown-complete notification or this watchdog — releases the quit.
    /// Sums the known drain budgets (the constants below) plus margin for
    /// the deliberately unbounded synchronous flush decode; a pathologically
    /// hung C call still trips the watchdog, and the user can always
    /// force-quit.
    private static let teardownWatchdogInterval: TimeInterval =
        CrispASREngine.drainTimeout + SessionController.translationDrainTimeout + 5

    private var repliedToTerminate = false
    private var teardownWatchdog: Timer?
    private var teardownCompleteObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's Settings scene ignores `.windowStyle(.hiddenTitleBar)`,
        // so the chrome is hidden at the AppKit level when the
        // lazily-created window becomes key on open.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window,
                      SettingsWindowController.isSettingsWindow(window),
                      window.titleVisibility != .hidden
                else { return }
                self?.hideTitleChrome(of: window)
            }
        }
        // Settings dismisses on any click outside it: losing key status is
        // exactly that — the click landed on the main window, the desktop,
        // or another app — so resign-key closes the window.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window,
                      SettingsWindowController.isSettingsWindow(window),
                      window.isVisible
                else { return }
                window.performClose(nil)
            }
        }
    }

    private func hideTitleChrome(of window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        repliedToTerminate = false
        // `.common` mode: termination can land while the user is mid-gesture
        // (tracking mode), where a `.default`-mode timer would never fire.
        let interval = Self.teardownWatchdogInterval
        let watchdog = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.replyToTerminate() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        teardownWatchdog = watchdog
        teardownCompleteObserver = NotificationCenter.default.addObserver(
            forName: .mimiTerminationTeardownComplete, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.replyToTerminate() }
        }
        // AppModel winds the session down (flush + translation tail), then
        // releases the warm ASR engine, then posts …TeardownComplete.
        NotificationCenter.default.post(name: .mimiAppWillTerminate, object: nil)
        return .terminateLater
    }

    private func replyToTerminate() {
        guard !repliedToTerminate else { return }
        repliedToTerminate = true
        teardownWatchdog?.invalidate()
        teardownWatchdog = nil
        if let observer = teardownCompleteObserver {
            NotificationCenter.default.removeObserver(observer)
            teardownCompleteObserver = nil
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
