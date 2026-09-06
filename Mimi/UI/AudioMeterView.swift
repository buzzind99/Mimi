import SwiftUI

/// Center-mirrored gradient meter with an edge fade, ported from
/// `MockAudioMeter`; bars come from the rolling level ring and flatline at
/// their stub height when idle.
struct AudioMeterView: View {
    var levels: [Double]
    var barHeight: CGFloat = 44

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                bar(at: index, level: level)
            }
        }
        .frame(maxWidth: .infinity)
        .background(glow)
    }

    private func bar(at index: Int, level: Double) -> some View {
        let normalized = min(max(level, 0), 1)
        let mid = Double(levels.count - 1) / 2
        let spread = Double(max(levels.count, 1)) / 2
        let offset = (Double(index) - mid) / spread
        let edgeFade = max(0.45, 1 - offset * offset * 0.55)
        return Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Theme.meterTeal.opacity(edgeFade), Theme.meterBlue.opacity(edgeFade * 0.85)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: max(6, normalized * barHeight))
    }

    private var glow: some View {
        LinearGradient(
            colors: [Theme.meterTeal.opacity(0.10), Theme.meterBlue.opacity(0.06)],
            startPoint: .top, endPoint: .bottom
        )
        .blur(radius: 12)
    }
}
