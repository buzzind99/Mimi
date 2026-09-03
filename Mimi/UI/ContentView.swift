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

/// Root view: onboarding until the model resolves, then the main panes.
struct ContentView: View {
    var model: AppModel
    var live: LivePartialState
    var latency: LatencyState

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
            Task { await model.refreshModelAvailability() }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            MainHeaderView(model: model)
            Divider()
            TranscriptView(model: model)
            Divider()
            LiveSubtitleView(live: live)
        }
        .safeAreaInset(edge: .bottom) {
            StatusBarView(model: model, latency: latency)
        }
    }
}
