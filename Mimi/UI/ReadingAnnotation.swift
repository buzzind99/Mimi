import Foundation

/// Reading annotation mode. Romaji and furigana are mutually exclusive —
/// exactly one (or neither) is shown; a shared UserDefaults key backs it.
enum ReadingAnnotation: String, CaseIterable, Identifiable {
    case none
    case romaji
    case furigana

    static let storageKey = "ReadingAnnotation"

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .none: "None"
        case .romaji: "Romaji"
        case .furigana: "Furigana"
        }
    }
}
