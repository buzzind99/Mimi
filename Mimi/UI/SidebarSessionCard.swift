import SwiftUI

/// SESSION card of the sidebar (file split for the lint gate): sentence,
/// duration, character, and lag stats over the shared card chrome. The
/// card shows in every cursor mode.
extension SidebarView {

    var sessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            KickerLabel("SESSION")
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
        .cardSurface()
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
