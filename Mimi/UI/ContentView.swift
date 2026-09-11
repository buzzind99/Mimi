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

/// Root view: onboarding until the model resolves, then the main shell —
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
        .preferredColorScheme($appearance.resolvedColorScheme)
        .background(TranslationSessionHost(model: model))
        .frame(minWidth: 860, minHeight: 600)
        .onAppear {
            Task { await model.refreshModelAvailability() }
        }
    }

    /// Whether the live strip owns the app's single dictionary
    /// popover: true only while the selection is anchored to the strip.
    /// Dismissal clears the selection only when the strip still owns it.
    /// (Binding shape shared via `AppModel.lookupPopoverBinding`.)
    private var liveStripLookupPresented: Binding<Bool> {
        model.lookupPopoverBinding(for: .liveStrip)
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                TranscriptView(model: model)
                LiveStripView(
                    live: live,
                    onCopy: { model.copySnippet($0) },
                    onLookup: { model.handleLookupTap($0, source: .liveStrip) }
                )
                // Strip-anchored popover: single non-virtualized view, so
                // the strip owns it while the selection's anchor is the
                // live strip. Source-keyed so a strip retap swaps content
                // in place instead of a dismiss+replace.
                .popover(isPresented: liveStripLookupPresented) {
                    if let selected = model.selectedLookup?.popoverItem(for: .liveStrip) {
                        DictionaryPopoverView(model: model, selected: selected)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                ToastStackView(center: model.toasts)
            }
            .overlay(alignment: .top) {
                NoticePillView(center: model.notices)
            }
        }
        .background(Theme.window)
    }
}
