import SwiftUI

@main
struct MimiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel())
    }

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
    }
}

/// Bridges AppKit (HUD panel).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let hud = HUDWindowController.shared

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Let AppModel wind the session down on quit.
        NotificationCenter.default.post(name: .mimiAppWillTerminate, object: nil)
    }
}
