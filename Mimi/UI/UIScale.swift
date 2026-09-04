import SwiftUI

/// UI text scale, applied as a font-size multiplier to content text in the
/// main window and the HUD. Persisted under one shared `UserDefaults` key
/// so both surfaces always scale together.
enum UIScale: Int, CaseIterable, Identifiable {
    case percent75 = 75
    case percent100 = 100
    case percent125 = 125
    case percent150 = 150
    case percent175 = 175
    case percent200 = 200

    static let storageKey = "UIScale"
    static let `default`: UIScale = .percent100

    var id: Int {
        rawValue
    }

    /// Font-size multiplier (1.0 at 100%).
    var factor: CGFloat {
        CGFloat(rawValue) / 100
    }

    var label: String {
        "\(rawValue)%"
    }

    /// Steps `delta` positions through `allCases`, clamped at both bounds.
    func step(_ delta: Int) -> UIScale {
        let cases = Self.allCases
        let index = cases.firstIndex(of: self) ?? 0
        return cases[min(max(index + delta, 0), cases.count - 1)]
    }
}

/// Property wrapper exposing the persisted UI scale (invalid stored values
/// fall back to 100%). Conforms to `DynamicProperty` so observing views
/// re-render on change; the projected value is a `Binding<UIScale>` for
/// controls.
@propertyWrapper
struct UIScaleSetting: DynamicProperty {
    @AppStorage(UIScale.storageKey) private var raw = UIScale.default.rawValue

    var wrappedValue: UIScale {
        get { UIScale(rawValue: raw) ?? .default }
        nonmutating set { raw = newValue.rawValue }
    }

    var projectedValue: Binding<UIScale> {
        Binding(
            get: { UIScale(rawValue: raw) ?? .default },
            set: { raw = $0.rawValue }
        )
    }
}

/// Point sizes for the macOS semantic text styles content text uses
/// (caption 11, body 13, callout 12, title3 15), multiplied by the UI-scale
/// factor. Visually identical to the semantic styles at 100%.
enum ScaledFont {
    static func caption(_ factor: CGFloat) -> Font {
        .system(size: 11 * factor)
    }

    static func body(_ factor: CGFloat) -> Font {
        .system(size: 13 * factor)
    }

    static func callout(_ factor: CGFloat) -> Font {
        .system(size: 12 * factor)
    }

    static func title3(_ factor: CGFloat) -> Font {
        .system(size: 15 * factor)
    }
}
