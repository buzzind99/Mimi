import AppKit
import SwiftUI

/// Main sidebar: brand header, session capsule, reading-aid picker,
/// engines/audio/session cards, and the toolbar row. Fixed 282pt, themed by
/// `Theme`; the transcript pane supplies the 1pt divider.
struct SidebarView: View {
    @Bindable var model: AppModel
    @AppStorage(ReadingAnnotation.storageKey) private var readingAnnotation = ReadingAnnotation.romaji
    @AppStorage(CursorMode.storageKey) private var cursorMode = CursorMode.none
    @AppStorage(UIScale.storageKey) private var uiScale = UIScale.default

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
            annotationPicker

            sectionLabel("CURSOR MODE")
            cursorPicker
                .padding(.bottom, 22)

            modeCards

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

    /// Pure mapping (unit-tested): phase → capsule presentation + ASR dot.
    private var status: SidebarStatus {
        SidebarStatus.map(phase: model.phase, isCheckingModel: model.isCheckingModel)
    }

    private var sessionButton: some View {
        Button {
            if status.isLiveSession {
                model.stop()
            } else {
                model.start()
            }
        } label: {
            Label(status.sessionTitle, systemImage: status.sessionIcon)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(status.isLiveSession ? Theme.Gradients.stop : Theme.Gradients.start)
                )
                .foregroundStyle(.white)
                .pointerStyle(.link)
        }
        .buttonStyle(.plain)
        .disabled(status.isSessionDisabled)
    }

    // MARK: - Annotation picker

    private var annotationPicker: some View {
        ModePicker(
            help: "Reading annotation for the Japanese text — romaji and furigana are mutually exclusive",
            modes: ReadingAnnotation.allCases, selection: $readingAnnotation,
            label: \.label
        )
    }

    private var cursorPicker: some View {
        ModePicker(
            help: "Click behavior for Japanese text — Copy places the clicked word on the pasteboard; Dictionary opens a lookup",
            modes: CursorMode.allCases, selection: $cursorMode,
            label: \.label
        )
    }
}

// MARK: - Cards

extension SidebarView {

    /// Which cards the sidebar shows per cursor mode: `.dictionary` swaps
    /// ENGINES + AUDIO for the DICTIONARY card; SESSION shows in every mode
    /// (below the `Spacer`, outside this set). Pure for tests.
    struct CardVisibility: Equatable {
        let engines: Bool
        let audio: Bool
        let dictionary: Bool

        static let enginePair = CardVisibility(engines: true, audio: true, dictionary: false)
        static let dictionaryMode = CardVisibility(engines: false, audio: false, dictionary: true)
    }

    static func showsCards(for cursorMode: CursorMode) -> CardVisibility {
        switch cursorMode {
        case .dictionary: .dictionaryMode
        default: .enginePair
        }
    }

    @ViewBuilder
    private var modeCards: some View {
        let visibility = Self.showsCards(for: cursorMode)
        if visibility.dictionary {
            // The card's internal GeometryReader slot claims the free
            // sidebar space (its senses list scrolls within it); priority
            // keeps the trailing `Spacer` at its minimum.
            DictionaryCardView(model: model)
                .layoutPriority(1)
                .padding(.bottom, 12)
        } else {
            enginesCard
                .padding(.bottom, 12)
            audioCard
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        KickerLabel(text)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private var enginesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("ENGINES")

            engineRow(
                title: "ASR · \(model.asrModelSettings.selected.displayName)",
                detail: asrDetail, detailColor: asrDetailColor, dotColor: dotColor(status.asrDot)
            )
            engineRow(
                title: "Translation · \(translationEngineName)",
                detail: translationDetail, detailColor: Theme.secondaryText,
                dotColor: translationDotColor
            )
        }
        .padding(14)
        .cardSurface()
    }

    private var asrDetail: String {
        model.engineIsMock ? "Mock — runtime not built" : model.asrModelSettings.selected.modelName
    }

    private var asrDetailColor: Color {
        model.engineIsMock ? Theme.dotYellow : Theme.secondaryText
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
        return (model.activeExternalProvider ?? model.translationSettings.selectedProvider).shortName
    }

    private var translationDetail: String {
        SidebarStatus.translationDetail(
            status: model.translationStatus,
            activeEngine: model.activeTranslationEngine,
            fallbackActive: translationFallbackLatched
        )
    }

    private var translationDotColor: Color {
        dotColor(SidebarStatus.DotTone(TranslationPill.map(
            status: model.translationStatus,
            activeEngine: model.activeTranslationEngine,
            fallbackActive: translationFallbackLatched
        ).tone))
    }

    private func dotColor(_ tone: SidebarStatus.DotTone) -> Color {
        switch tone {
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

    // The SESSION card (and the MARK: - Session card block) lives in
    // `SidebarSessionCard.swift` (file split for the lint gate).
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
        .cardSurface(radius: 9)
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
                .cardSurface(radius: 9)
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
                .cardSurface(radius: 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(iconButtonShape)
        .help("Settings")
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if SettingsWindowController.isSettingsWindow(note.object) {
                isSettingsOpen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if SettingsWindowController.isSettingsWindow(note.object) {
                isSettingsOpen = false
            }
        }
    }

    private func toggleSettings() {
        if let settingsWindow = SettingsWindowController.visibleWindow() {
            SettingsWindowController.close(settingsWindow)
        } else {
            isSettingsOpen = true
            openSettings()
        }
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
