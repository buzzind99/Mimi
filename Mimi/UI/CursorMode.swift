import SwiftUI

/// Click behavior for the Japanese text surface: `.copy` places the clicked
/// run on the pasteboard (with a confirmation toast); `.dictionary` opens a
/// definition lookup for the tapped word (inert where the host does not
/// handle lookups, e.g. the HUD); `.none` keeps clicks inert. A shared
/// UserDefaults key backs it.
enum CursorMode: String, CaseIterable, Identifiable {
    case none
    case dictionary
    case copy

    static let storageKey = "CursorMode"

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .none: "None"
        case .dictionary: "Dictionary"
        case .copy: "Copy"
        }
    }
}

/// Property wrapper exposing the persisted cursor mode as a decoded
/// `CursorMode` (invalid stored values fall back to `.none`). Conforms to
/// `DynamicProperty` so observing views re-render on change; the projected
/// value is a `Binding<CursorMode>` for controls.
@propertyWrapper
struct CursorModeSetting: DynamicProperty {
    @AppStorage(CursorMode.storageKey) private var raw = CursorMode.none.rawValue

    var wrappedValue: CursorMode {
        get { CursorMode(rawValue: raw) ?? .none }
        nonmutating set { raw = newValue.rawValue }
    }

    var projectedValue: Binding<CursorMode> {
        Binding(
            get: { CursorMode(rawValue: raw) ?? .none },
            set: { raw = $0.rawValue }
        )
    }
}
