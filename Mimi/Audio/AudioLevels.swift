/// Audio measurement helpers shared by the ASR engines and the session log.
enum AudioLevels {
    /// Root-mean-square energy of a PCM buffer (0 for empty input). The
    /// shared loudness metric behind the ASR speech backstop and the debug
    /// ingress log.
    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0) { $0 + $1 * $1 }
        return (energy / Float(samples.count)).squareRoot()
    }
}
