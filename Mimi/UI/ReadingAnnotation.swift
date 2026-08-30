import SwiftUI

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

/// Property wrapper exposing the persisted annotation mode as a decoded
/// `ReadingAnnotation` (invalid stored values fall back to `.romaji`).
/// Conforms to `DynamicProperty` so observing views re-render on change;
/// the projected value is a `Binding<ReadingAnnotation>` for controls.
@propertyWrapper
struct ReadingAnnotationSetting: DynamicProperty {
    @AppStorage(ReadingAnnotation.storageKey) private var raw = ReadingAnnotation.romaji.rawValue

    var wrappedValue: ReadingAnnotation {
        get { ReadingAnnotation(rawValue: raw) ?? .romaji }
        nonmutating set { raw = newValue.rawValue }
    }

    var projectedValue: Binding<ReadingAnnotation> {
        Binding(
            get: { ReadingAnnotation(rawValue: raw) ?? .romaji },
            set: { raw = $0.rawValue }
        )
    }
}
