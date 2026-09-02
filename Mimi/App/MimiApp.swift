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
        NotificationCenter.default.post(name: .init("MimiAppWillTerminate"), object: nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Model") {
                LabeledContent("Status") {
                    if let url = model.modelURL {
                        Text(url.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Not downloaded").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Model") {
                    Text(ModelLocator.modelID)
                }
                LabeledContent("Models folder") {
                    Text(ModelLocator.modelsDirectory.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Re-check model") {
                    Task { await model.refreshModelAvailability() }
                }
            }
            Section("Session") {
                LabeledContent("Entries") { Text("\(model.entries.count)") }
                LabeledContent("Engine") {
                    Text(model.engineIsMock ? "Mock (runtime not installed)" : "CrispASR · Qwen3-ASR 0.6B (Metal)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 300)
    }
}
