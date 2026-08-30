import SwiftUI

/// Header row of the main window: session controls, reading-annotation
/// picker, mock-ASR badge, and the export menu.
struct MainHeaderView: View {
    @ObservedObject var model: AppModel
    @ReadingAnnotationSetting private var readingAnnotation

    var body: some View {
        HStack(spacing: 12) {
            sessionButton

            Toggle(isOn: $model.hudVisible) {
                Label("HUD", systemImage: "rectangle.on.rectangle")
            }
            .toggleStyle(.checkbox)
            .help("Floating always-on-top subtitle overlay (click-through, resizable)")

            Picker("Reading", selection: $readingAnnotation) {
                ForEach(ReadingAnnotation.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help(
                "Reading annotation for the Japanese text — romaji and furigana are mutually exclusive"
            )

            Spacer()

            if model.engineIsMock {
                Text("MOCK ASR")
                    .font(.caption).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                    .help("Native ASR runtime not found — running the built-in mock so you can exercise the pipeline. Build it with scripts/build_runtime.sh.")
            }

            exportMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sessionButton: some View {
        Button {
            if model.phase == .running || model.phase == .sourceLost {
                model.stop()
            } else {
                model.start()
            }
        } label: {
            Label(
                model.phase == .running || model.phase == .sourceLost ? "Stop" : "Start",
                systemImage: model.phase == .running ? "stop.circle.fill" : "play.circle.fill"
            )
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.phase == .running ? .red : .accentColor)
        .disabled(model.phase == .starting || model.phase == .stopping)
    }

    private var exportMenu: some View {
        Menu {
            Button("Copy transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.exportText(), forType: .string)
            }
            .disabled(!model.isExportable)

            Divider()

            ForEach(SessionExporter.Format.allCases) { format in
                Button("Export \(format.rawValue)…") {
                    runExport(format)
                }
                .disabled(!model.isExportable)
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(!model.isExportable)
    }

    private func runExport(_ format: SessionExporter.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.fileExtension == "json" ? .json : .plainText]
        panel.nameFieldStringValue = "mimi-session.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try model.export(format: format)
            try data.write(to: url)
        } catch {
            model.errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
