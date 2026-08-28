import SwiftUI
import Translation

/// Hidden helper that acquires the `TranslationSession` from SwiftUI and
/// feeds it to the queue. This is also what surfaces the one-time OS
/// language-pack download prompt.
struct TranslationSessionHost: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.translationConfig) { session in
                await model.translationQueue.run(with: session)
            }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LivePartialState

    var body: some View {
        Group {
            if model.phase == .needsModel {
                OnboardingView(model: model)
            } else {
                mainContent
            }
        }
        .background(TranslationSessionHost(model: model))
        .frame(minWidth: 860, minHeight: 600)
        .onAppear {
            model.refreshModelAvailability()
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            liveSubtitle
            Divider()
            transcript
        }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    // MARK: - Header (controls)

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if model.phase == .running || model.phase == .sourceLost {
                    model.stop()
                } else {
                    model.start()
                }
            } label: {
                Label(
                    model.phase == .running || model.phase == .sourceLost ? "Stop" : "Start",
                    systemImage: model.phase == .running ? "stop.circle.fill" : "play.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.phase == .running ? .red : .accentColor)
            .disabled(model.phase == .starting || model.phase == .stopping)

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
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                    .help("Native ASR runtime not found — running the built-in mock so you can exercise the pipeline. Build it with scripts/build_runtime.sh.")
            }

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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Live subtitle (high-frequency state; only this row observes partials)

    private var liveSubtitle: some View {
        HStack {
            if live.partial.isEmpty {
                Text("…")
                    .foregroundColor(.secondary.opacity(0.35))
            } else {
                Text(live.partial)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    // MARK: - Transcript (two aligned panes in one virtualized scroll)

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.entries.isEmpty {
                        VStack(spacing: 8) {
                            Text("No transcript yet")
                                .font(.title3)
                                .foregroundColor(.secondary)
                            Text("Play any Japanese audio on your Mac (e.g. a livestream in your browser) and press Start.")
                                .font(.callout)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                    ForEach(model.entries) { entry in
                        TranscriptRow(entry: entry)
                            .id(entry.id)
                        Divider().opacity(0.15)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .onChange(of: model.entries.count) { _, _ in
                if let last = model.entries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            statusBadge
            Spacer()
            Text(String(format: "≈ %.1f s behind", model.latencySeconds))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.phase {
        case .running:
            Label("Capturing", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.green)
        case .sourceLost:
            Label("Source lost — start capture again", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case .starting:
            Label("Starting…", systemImage: "hourglass")
                .font(.caption)
        case .stopping:
            Label("Stopping…", systemImage: "hourglass.bottomhalf.filled")
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.caption).foregroundStyle(.red)
        case .needsModel:
            Label("Model needed", systemImage: "arrow.down.circle")
                .font(.caption)
        case .idle:
            Label("Idle", systemImage: "circle")
                .font(.caption).foregroundStyle(.secondary)
        }

        switch model.translationStatus {
        case .unavailable(let message):
            HStack(spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("Retry") { model.retryTranslation() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case .translating:
            Text("Translating…").font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }

        if let message = model.errorMessage {
            Text(message).font(.caption).foregroundStyle(.red)
        }
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

/// One aligned row: JP final (timestamped) | EN translation (same start time).
struct TranscriptRow: View {
    let entry: SessionEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SessionClock.timestamp(entry.sentence.startS))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
                Text(entry.sentence.text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SessionClock.timestamp(entry.sentence.startS))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 52, alignment: .trailing)
                if entry.translations.isEmpty {
                    Text("…")
                        .foregroundColor(.secondary.opacity(0.3))
                } else {
                    Text(entry.translations.map(\.text).joined(separator: " / "))
                        .foregroundColor(.teal)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}
