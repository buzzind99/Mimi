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

/// Fixed point sizes standing in for the macOS semantic text styles content
/// text uses — body 13, callout 12, title3 15 match the semantic sizes;
/// caption is 11 where the semantic caption is 10 — multiplied by the
/// UI-scale factor.
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
