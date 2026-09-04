import Foundation

/// Which ASR GGUF the app uses. Raw values are the UserDefaults payload
/// (`"asr.model"`), so they must stay stable.
enum ASRModelChoice: String, CaseIterable, Identifiable {
    /// SenseVoice-Small q8_0 — the default: small download, fast start.
    case lite
    /// FunASR-Nano 2512 q8_0 — opt-in full model.
    case full

    var id: String {
        rawValue
    }

    /// UI-facing name (Settings rows, onboarding cards).
    var displayName: String {
        switch self {
        case .lite: "Lite"
        case .full: "Full"
        }
    }

    /// Underlying speech-model name (Settings row subtitle).
    var modelName: String {
        switch self {
        case .lite: "SenseVoice-Small"
        case .full: "FunASR-Nano-2512"
        }
    }

    /// GGUF file name inside the shared models directory (both choices live
    /// side-by-side, so switching never re-downloads).
    var ggufFileName: String {
        switch self {
        case .lite: "sensevoice-small-q8_0.gguf"
        case .full: "funasr-nano-2512-q8_0.gguf"
        }
    }

    /// Hugging Face repo id — also the session-metadata `model` value.
    var modelID: String {
        switch self {
        case .lite: "sensevoice-small-GGUF"
        case .full: "funasr-nano-GGUF"
        }
    }

    /// Hugging Face resolve URL for the pinned GGUF file.
    var downloadURL: URL {
        URL(string: "https://huggingface.co/cstr/\(modelID)/resolve/main/\(ggufFileName)")!
    }

    /// Pinned SHA-256 (release-time integrity check). Lite's pin is the
    /// digest of the repo's dev GGUF; Full's is the Hugging Face LFS oid.
    var pinnedSHA256: String {
        switch self {
        case .lite:
            "b7126f2cb4fe0440cb76f652aed3f1d67813ca1d12088a13b0cafb8884a72a57"
        case .full:
            "dac5e1b95659c0a95b2a1dc60083eb17740454a921ec39f9c24e50b930ca31ab"
        }
    }

    /// Approximate download size for UI copy.
    var approximateSize: String {
        switch self {
        case .lite: "~250 MB"
        case .full: "~1.2 GB"
        }
    }

    /// One-line tradeoff copy for the onboarding cards and Settings rows.
    var blurb: String {
        switch self {
        case .lite:
            "SenseVoice-Small. Smaller download, fast startup — great default for everyday transcription."
        case .full:
            "FunASR-Nano-2512. Larger download for potentially more accurate transcription."
        }
    }
}
