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
    @ObservedObject var latency: LatencyState
    @State private var isAtTop = true
    @State private var pulsing = false
    @State private var scrollPosition = ScrollPosition()
    @State private var pendingInsertCompensation = false

    private struct ScrollSnapshot: Equatable {
        let offset: CGFloat
        let contentHeight: CGFloat
    }

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

    // Fixed-height live row: slots never resize so empty↔filled transitions
    // don't jitter. Dot pulses only while a partial is streaming in.

    private var liveSubtitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.teal)
                    .frame(width: 7, height: 7)
                    .opacity(pulsing && !live.partial.isEmpty ? 0.45 : 1)
                    .animation(
                        live.partial.isEmpty
                            ? nil
                            : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: pulsing)
                    .opacity(live.partial.isEmpty ? 0.35 : 1)

                Text("live")
                    .font(.caption.monospaced().bold())
                    .foregroundColor(.teal)
                    .opacity(live.partial.isEmpty ? 0.5 : 1)
            }
            .onChange(of: live.partial.isEmpty) { _, isEmpty in
                guard !isEmpty else { return }
                pulsing = false
                DispatchQueue.main.async { pulsing = true }
            }

            if live.partial.isEmpty {
                Text("…")
                    .font(.system(size: 17, weight: .medium))
                    .italic()
                    .foregroundColor(.secondary.opacity(0.35))
                    .frame(height: 22, alignment: .leading)
            } else {
                Text(live.partial)
                    .font(.system(size: 17, weight: .medium))
                    .italic()
                    .foregroundColor(.teal)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(height: 22, alignment: .leading)
            }

            Group {
                if let romaji = RomajiAnnotator.romaji(for: live.partial) {
                    Text(romaji)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.caption.monospaced())
            .foregroundColor(.secondary.opacity(0.55))
            .frame(height: 14, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    // MARK: - Transcript (stacked subtitle-style rows in one virtualized scroll)

    // Newest sentence first. While the user is at the top, finalizing a
    // sentence pushes older rows down with a spring; scrolled down, the
    // scroll offset is compensated by the inserted row's height so the
    // visible content doesn't move at all.

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
                    ForEach(model.entries.reversed()) { entry in
                        TranscriptRow(entry: entry)
                            .id(entry.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity))
                        Divider().opacity(0.15)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .animation(
                    isAtTop ? .spring(response: 0.35, dampingFraction: 0.85) : nil,
                    value: model.entries.count)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geo in
                ScrollSnapshot(offset: geo.contentOffset.y, contentHeight: geo.contentSize.height)
            } action: { old, new in
                isAtTop = new.offset < 1
                guard pendingInsertCompensation, new.contentHeight > old.contentHeight else { return }
                pendingInsertCompensation = false
                scrollPosition.scrollTo(
                    x: 0,
                    y: new.offset + (new.contentHeight - old.contentHeight))
            }
            .onChange(of: model.entries.count) { _, _ in
                if isAtTop {
                    guard let newest = model.entries.last else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(newest.id, anchor: .top)
                    }
                } else {
                    // A row is being inserted above the viewport; grow the
                    // offset by the same amount so content stays visually put.
                    pendingInsertCompensation = true
                }
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        StatusBarView(model: model, latency: latency)
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

/// Status bar isolated into its own view so the high-frequency latency
/// estimate re-renders only this bar, not the transcript or the header.
private struct StatusBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var latency: LatencyState

    var body: some View {
        HStack(spacing: 16) {
            statusBadge
            Spacer()
            Text(String(format: "≈ %.1f s behind", latency.seconds))
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
}

/// One stacked row: timestamp range header, EN translation (italic),
/// JP sentence, romaji reading. `Equatable` so SwiftUI skips unchanged rows
/// when the transcript re-diffs.
struct TranscriptRow: View, Equatable {
    let entry: SessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(entry.startTimestamp) – \(entry.endTimestamp)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary.opacity(0.6))

            if let joined = entry.joinedTranslations {
                Text(joined)
                    .italic()
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("…")
                    .italic()
                    .foregroundColor(.secondary.opacity(0.3))
            }

            Text(entry.sentence.text)
                .font(.system(size: 17, weight: .medium))
                .textSelection(.enabled)

            if let romaji = RomajiAnnotator.romaji(for: entry.sentence.text) {
                Text(romaji)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary.opacity(0.55))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
