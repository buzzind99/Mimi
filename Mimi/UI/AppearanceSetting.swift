import SwiftUI

/// Window appearance. Persisted (UserDefaults key `"Appearance"`); the
/// resolved scheme is applied at the window root via `.preferredColorScheme`,
/// which also drives the adaptive `Theme` token resolution.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "Appearance"

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Value for `.preferredColorScheme`; nil follows the system.
    var resolvedColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Property wrapper exposing the persisted appearance as a decoded
/// `Appearance` (invalid stored values fall back to `.system`). Mirrors
/// `ReadingAnnotationSetting`: conforms to `DynamicProperty` so observing
/// views re-render on change; the projected value is a
/// `Binding<Appearance>` for controls.
@propertyWrapper
struct AppearanceSetting: DynamicProperty {
    @AppStorage(Appearance.storageKey) private var raw = Appearance.system.rawValue

    var wrappedValue: Appearance {
        get { Appearance(rawValue: raw) ?? .system }
        nonmutating set { raw = newValue.rawValue }
    }

    var projectedValue: Binding<Appearance> {
        Binding(
            get: { Appearance(rawValue: raw) ?? .system },
            set: { raw = $0.rawValue }
        )
    }
}
