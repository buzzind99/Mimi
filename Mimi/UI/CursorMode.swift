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
