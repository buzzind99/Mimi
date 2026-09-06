import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main sidebar: brand header, session capsule, reading-aid picker,
/// engines/audio/session cards, and the toolbar row. Fixed 282pt, themed by
/// `Theme`; the transcript pane supplies the 1pt divider.
struct SidebarView: View {
    @Bindable var model: AppModel
    @ReadingAnnotationSetting private var readingAnnotation
    @UIScaleSetting private var uiScale

    @State private var exportPresented = false
    @State private var exportFormat: SessionExporter.Format = .txt
    @State private var exportData: Data?
    @State private var isSettingsOpen = false

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
                .padding(.bottom, 26)

            sessionButton

            sectionLabel("ANNOTATION")
            readingPicker
                .padding(.bottom, 22)

            enginesCard
                .padding(.bottom, 12)
            audioCard

            Spacer()

            sessionCard
                .padding(.bottom, 14)

            toolbar
        }
        .padding(.top, 16)
        .padding([.horizontal, .bottom], 20)
        .frame(width: 282, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .fileExporter(
            isPresented: $exportPresented,
            document: exportData.map { ExportDocument(data: $0) },
            contentTypes: [exportFormat.contentType],
            defaultFilename: "mimi-session.\(exportFormat.fileExtension)"
        ) { result in
            if case let .failure(error) = result {
                model.toasts.post(
                    key: ToastKey.exportFailed, style: .yellowAuto,
                    title: "Export failed", body: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Brand header

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.Gradients.brand)
                Text("耳")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Mimi")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Japanese → English")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: - Session capsule

    private var sessionButton: some View {
        Button {
            if model.phase == .running || model.phase == .sourceLost {
                model.stop()
            } else {
                model.start()
            }
        } label: {
            Label(sessionButtonTitle, systemImage: sessionButtonIcon)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(sessionButtonGradient))
                .foregroundStyle(.white)
                .pointerStyle(.link)
        }
        .buttonStyle(.plain)
        .disabled(sessionButtonDisabled)
    }

    private var sessionButtonTitle: String {
        switch model.phase {
        case .running, .sourceLost: "Stop session"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .idle, .needsModel, .failed: "Start session"
        }
    }

    private var sessionButtonIcon: String {
        model.phase == .running || model.phase == .sourceLost ? "stop.fill" : "play.fill"
    }

    private var sessionButtonGradient: LinearGradient {
        model.phase == .running || model.phase == .sourceLost
            ? Theme.Gradients.stop
            : Theme.Gradients.start
    }

    /// While model discovery is in flight Start is gated (`isCheckingModel`);
    /// Stop must stay reachable from a live session.
    private var sessionButtonDisabled: Bool {
        model.phase == .starting || model.phase == .stopping
            || (model.isCheckingModel && model.phase != .running && model.phase != .sourceLost)
    }

    // MARK: - Reading aids

    private var readingPicker: some View {
        HStack(spacing: 2) {
            ForEach(ReadingAnnotation.allCases) { mode in
                readingSegment(mode)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.cardFill))
        .help(
            "Reading annotation for the Japanese text — romaji and furigana are mutually exclusive"
        )
    }

    private func readingSegment(_ mode: ReadingAnnotation) -> some View {
        let selected = readingAnnotation == mode
        return Button {
            readingAnnotation = mode
        } label: {
            Text(mode.label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.primaryText : Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule().fill(Theme.accentPink)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule())
    }
}

// MARK: - Cards

extension SidebarView {

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.secondaryText)
            .kerning(1.2)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private var enginesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ENGINES")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .kerning(1.2)

            engineRow(
                title: "ASR · \(model.asrModelSettings.selected.displayName)",
                detail: asrDetail, detailColor: asrDetailColor, dotColor: asrDotColor
            )
            engineRow(
                title: "Translation · \(translationEngineName)",
                detail: translationDetail, detailColor: Theme.secondaryText,
                dotColor: translationDotColor
            )
        }
        .padding(14)
        .background(cardChrome)
    }

    private var asrDetail: String {
        model.engineIsMock ? "Mock — runtime not built" : model.asrModelSettings.selected.modelName
    }

    private var asrDetailColor: Color {
        model.engineIsMock ? Theme.dotYellow : Theme.secondaryText
    }

    private var asrDotColor: Color {
        switch model.phase {
        case .running: Theme.dotGreen
        case .starting, .stopping: Theme.dotYellow
        case .sourceLost, .failed: Theme.liveRed
        case .idle, .needsModel: Theme.secondaryText
        }
    }

    /// The latched Apple fallback stays visible after the fresh Apple run
    /// publishes `.ready` — otherwise "On-device (fallback)" would flash for
    /// under a second and the card would read as healthy green.
    private var translationFallbackLatched: Bool {
        model.translationFallbackActive && model.activeTranslationEngine == .apple
    }

    /// Names the engine actually attached to the queue: an external run
    /// names `activeExternalProvider` (recorded at attachment time), never
    /// the picker — a mid-session selection change must not relabel an
    /// engine the queue isn't using.
    private var translationEngineName: String {
        guard model.activeTranslationEngine == .external else { return "Apple" }
        return switch model.activeExternalProvider ?? model.translationSettings.selectedProvider {
        case .apple: "Apple"
        case .google: "Google"
        case .deepl: "DeepL"
        case .openrouter: "OpenRouter"
        }
    }

    private var translationDetail: String {
        if translationFallbackLatched {
            return "On-device (fallback)"
        }
        return switch model.translationStatus {
        case .degraded: "On-device (fallback)"
        case .unavailable: "Unavailable"
        case .ready, .translating, .retrying, .idle:
            model.activeTranslationEngine == .apple ? "On-device" : "External"
        }
    }

    private var translationDotColor: Color {
        switch TranslationPill.map(
            status: model.translationStatus,
            activeEngine: model.activeTranslationEngine,
            fallbackActive: translationFallbackLatched
        ).tone {
        case .green: Theme.dotGreen
        case .yellow: Theme.dotYellow
        case .red: Theme.liveRed
        case .neutral: Theme.secondaryText
        }
    }

    private func engineRow(
        title: String, detail: String, detailColor: Color, dotColor: Color
    ) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(detailColor)
            }
            Spacer()
        }
    }

    private var audioCard: some View {
        AudioCardView(state: model.audioLevel)
    }

    // MARK: - Session card

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SESSION")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .kerning(1.2)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                stat(value: "\(model.entries.count)", label: "Sentences")
                durationStat
                stat(value: "\(model.sessionCharacterCount)", label: "Characters")
                stat(
                    value: model.latency.seconds.formatted(.number.precision(.fractionLength(1)))
                        + "s",
                    label: "Lag"
                )
            }
        }
        .padding(12)
        .background(cardChrome)
    }

    /// Duration ticks at 1 s while running (now − startedAt); frozen at
    /// endedAt after stop, at captureLostAt during a source-lost outage
    /// (the clock resumes on restart recovery); "—" before the first session.
    @ViewBuilder
    private var durationStat: some View {
        if model.phase == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                stat(
                    value: Self.durationText(from: model.sessionStartedAt, to: context.date),
                    label: "Duration"
                )
            }
        } else {
            stat(value: frozenDurationText, label: "Duration")
        }
    }

    private var frozenDurationText: String {
        guard let started = model.sessionStartedAt else { return "—" }
        return Self.durationText(
            from: started, to: model.sessionEndedAt ?? model.captureLostAt ?? Date()
        )
    }

    static func durationText(from start: Date?, to end: Date) -> String {
        guard let start else { return "—" }
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.tileFill))
    }
}

// MARK: - Toolbar

extension SidebarView {

    private var toolbar: some View {
        HStack(spacing: 8) {
            exportMenu
            hudToggleButton
            Spacer()
            scaleStepper
            settingsButton
        }
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
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(!model.isExportable)
        .frame(width: 34, height: 32)
        .background(iconButtonBackground)
        .hoverHighlight(iconButtonShape, isEnabled: model.isExportable)
        .help("Copy or export the session transcript")
    }

    private var hudToggleButton: some View {
        Button {
            model.hudVisible.toggle()
        } label: {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(model.hudVisible ? Theme.accentPink : Theme.primaryText.opacity(0.7))
                .frame(width: 34, height: 32)
                .background(iconButtonBackground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(iconButtonShape)
        .help("Floating always-on-top subtitle overlay (click-through, resizable)")
    }

    private var settingsButton: some View {
        Button {
            toggleSettings()
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(isSettingsOpen ? Theme.accentPink : Theme.primaryText.opacity(0.7))
                .frame(width: 34, height: 32)
                .background(iconButtonBackground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(iconButtonShape)
        .help("Settings")
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if isSettingsWindow(note.object) {
                isSettingsOpen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if isSettingsWindow(note.object) {
                isSettingsOpen = false
            }
        }
    }

    /// SwiftUI's Settings scene window identifier.
    private static let settingsWindowID = "com_apple_SwiftUI_Settings_window"

    private func isSettingsWindow(_ object: Any?) -> Bool {
        (object as? NSWindow)?.identifier?.rawValue.hasPrefix(Self.settingsWindowID) == true
    }

    private func toggleSettings() {
        if let window = NSApp.windows.first(where: {
            // SwiftUI keeps the closed Settings window cached in `windows`,
            // so check visibility rather than mere existence.
            $0.identifier?.rawValue == Self.settingsWindowID && $0.isVisible
        }) {
            window.performClose(nil)
        } else {
            isSettingsOpen = true
            openSettings()
        }
    }

    private var iconButtonBackground: some View {
        iconButtonShape
            .fill(Theme.cardFill)
            .overlay(iconButtonShape.stroke(Theme.cardStroke))
    }

    private var iconButtonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    private var scaleStepper: some View {
        HStack(spacing: 0) {
            stepButton("minus", isLeading: true, isEnabled: uiScale != .percent75) {
                uiScale = uiScale.step(-1)
            }
            .accessibilityLabel("Decrease text size")

            Text(uiScale.label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 40, height: 32)
                .background(Theme.tileFill)
                .help("Text size for the transcript and HUD")

            stepButton("plus", isLeading: false, isEnabled: uiScale != .percent200) {
                uiScale = uiScale.step(1)
            }
            .accessibilityLabel("Increase text size")
        }
    }

    private func stepButton(
        _ systemImage: String, isLeading: Bool, isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.primaryText.opacity(0.7))
                .frame(width: 26, height: 32)
                .background(
                    Theme.cardFill.clipShape(stepShape(isLeading: isLeading))
                )
                .overlay(alignment: isLeading ? .trailing : .leading) {
                    Rectangle().fill(Theme.divider).frame(width: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .hoverHighlight(stepShape(isLeading: isLeading), isEnabled: isEnabled)
    }

    private func stepShape(isLeading: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isLeading ? 9 : 0,
            bottomLeadingRadius: isLeading ? 9 : 0,
            bottomTrailingRadius: isLeading ? 0 : 9,
            topTrailingRadius: isLeading ? 0 : 9,
            style: .continuous
        )
    }

    private func runExport(_ format: SessionExporter.Format) {
        do {
            exportFormat = format
            exportData = try model.export(format: format)
            exportPresented = true
        } catch {
            model.toasts.post(
                key: ToastKey.exportFailed, style: .yellowAuto,
                title: "Export failed", body: error.localizedDescription
            )
        }
    }
}

/// Card chrome (fill + stroke) shared by the sidebar cards and the audio
/// leaf below; fileprivate so `AudioCardView` can reuse it standalone.
private var cardChrome: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Theme.cardFill)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.cardStroke)
        )
}

/// The sidebar AUDIO card as an observation leaf: it reads `AudioLevelState`
/// directly, so meter updates (poll-tick staged RMS) re-render only this
/// card — never the whole sidebar body with its engine/session cards.
private struct AudioCardView: View {
    let state: AudioLevelState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AUDIO")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .kerning(1.2)
                Spacer()
                Text(state.currentDB)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            AudioMeterView(levels: state.levels)
                .frame(height: 44)
        }
        .padding(14)
        .background(cardChrome)
    }
}

/// Minimal `FileDocument` wrapper that hands the prepared export payload to
/// SwiftUI's `fileExporter`.
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
