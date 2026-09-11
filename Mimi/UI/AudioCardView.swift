import SwiftUI

/// The sidebar AUDIO card as an observation leaf: it reads `AudioLevelState`
/// directly, so meter updates (poll-tick staged RMS) re-render only this
/// card — never the whole sidebar body with its engine/session cards.
struct AudioCardView: View {
    let state: AudioLevelState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                KickerLabel("AUDIO")
                Spacer()
                Text(state.currentDB)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            AudioMeterView(levels: state.levels)
                .frame(height: 44)
        }
        .padding(14)
        .cardSurface()
    }
}
