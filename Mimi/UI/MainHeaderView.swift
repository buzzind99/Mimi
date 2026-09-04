import SwiftUI
import UniformTypeIdentifiers

/// Header row of the main window: session controls, reading-annotation
/// picker, mock-ASR badge, UI-scale stepper, and the export menu.
struct MainHeaderView: View {
    @Bindable var model: AppModel
    @ReadingAnnotationSetting private var readingAnnotation
    @UIScaleSetting private var uiScale

    @State private var exportPresented = false
    @State private var exportFormat: SessionExporter.Format = .txt
    @State private var exportData: Data?

    var body: some View {
        HStack(spacing: 12) {
            sessionButton

            Toggle(isOn: $model.hudVisible) {
                Label("HUD", systemImage: "rectangle.on.rectangle")
            }
            .toggleStyle(.checkbox)
            .help("Floating always-on-top subtitle overlay (click-through, resizable)")

            Spacer()

            if model.engineIsMock {
                Text("MOCK ASR")
                    .font(.caption).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.25)))
                    .help(
                        "Native ASR runtime not found — running the built-in mock so you can "
                            + "exercise the pipeline. Build it with scripts/build_runtime.sh."
                    )
            }

            scaleStepper

            exportMenu

            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .overlay {
            Picker("Reading", selection: $readingAnnotation) {
                ForEach(ReadingAnnotation.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(
                "Reading annotation for the Japanese text — romaji and furigana are mutually exclusive"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .fileExporter(
            isPresented: $exportPresented,
            document: exportData.map { ExportDocument(data: $0) },
            contentTypes: [exportFormat.contentType],
            defaultFilename: "mimi-session.\(exportFormat.fileExtension)"
        ) { result in
            if case let .failure(error) = result {
                model.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
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
        // While model discovery is in flight Start is gated (`isCheckingModel`);
        // Stop must stay reachable from a live session.
        .disabled(
            model.phase == .starting || model.phase == .stopping
                || (model.isCheckingModel && model.phase != .running && model.phase != .sourceLost)
        )
    }

    private var exportMenu: some View {
        Menu {
            Button("Copy transcript") {
                model.copyTranscript()
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

    /// – / percentage / + control for the shared text scale. Steps the
    /// persisted `UIScale` with the bounds disabled; scales content text in
    /// the main window and the HUD, not header/status chrome.
    private var scaleStepper: some View {
        HStack(spacing: 4) {
            Button {
                uiScale = uiScale.step(-1)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(uiScale == .percent75)
            .help("Decrease text size")

            Text(uiScale.label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36)
                .help("Text size for the transcript and HUD")

            Button {
                uiScale = uiScale.step(1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(uiScale == .percent200)
            .help("Increase text size")
        }
    }

    private func runExport(_ format: SessionExporter.Format) {
        do {
            exportFormat = format
            exportData = try model.export(format: format)
            exportPresented = true
        } catch {
            model.errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// Minimal `FileDocument` wrapper that hands the prepared export payload to
/// SwiftUI's `fileExporter` (the panel only ever writes it; nothing reads).
private struct ExportDocument: FileDocument {
    let data: Data

    static var readableContentTypes: [UTType] {
        []
    }

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
