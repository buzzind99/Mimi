import SwiftUI
import Translation

/// Hidden helper that acquires the `TranslationSession` from SwiftUI and
/// feeds it to the queue. This is also what surfaces the one-time OS
/// language-pack download prompt.
struct TranslationSessionHost: View {
    var model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.translationConfig) { session in
                await model.translationQueue.run(with: AppleSessionEngine(session))
            }
    }
}

/// Root view: onboarding until the model resolves, then the Sakura Studio
/// shell — sidebar | 1pt divider | transcript pane with the live strip and
/// the toast stack overlaid top-trailing.
struct ContentView: View {
    var model: AppModel
    var live: LivePartialState
    var latency: LatencyState

    @AppearanceSetting private var appearance

    var body: some View {
        Group {
            if model.phase == .needsModel {
                OnboardingView(model: model)
            } else {
                mainContent
            }
        }
        .preferredColorScheme(appearance.resolvedColorScheme)
        .background(TranslationSessionHost(model: model))
        .frame(minWidth: 860, minHeight: 600)
        .onAppear {
            Task { await model.refreshModelAvailability() }
        }
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
            VStack(spacing: 0) {
                TranscriptView(model: model)
                LiveStripView(live: live)
            }
            .overlay(alignment: .topTrailing) {
                ToastStackView(center: model.toasts)
            }
        }
        .background(Theme.window)
    }
}
