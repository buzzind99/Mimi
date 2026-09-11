import AppKit
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

    /// SF Symbol shown beside the label in the settings appearance picker.
    var systemImage: String {
        switch self {
        case .system: "laptopcomputer"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// Tracks the system-wide color scheme so `.system` can resolve to a
/// concrete `ColorScheme`. Passing `nil` (the natural "follow the system"
/// encoding) to `.preferredColorScheme` fails to revert a previously applied
/// explicit scheme on macOS — the window content keeps the old appearance
/// while the chrome follows the system — so the scheme must always be
/// explicit, which in turn requires knowing the current system value.
@MainActor
final class SystemSchemeObserver: ObservableObject {
    static let shared = SystemSchemeObserver()

    @Published private(set) var colorScheme = SystemSchemeObserver.currentSystemScheme()

    private init() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemThemeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func systemThemeChanged() {
        colorScheme = Self.currentSystemScheme()
    }

    private static func currentSystemScheme() -> ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .dark : .light
    }
}

/// Property wrapper exposing the persisted appearance. Conforms to
/// `DynamicProperty` so observing views re-render on change; the projected
/// value is a `Binding<Appearance>` for controls plus the always-concrete
/// scheme for `.preferredColorScheme` at the window root.
@MainActor
@propertyWrapper
struct AppearanceSetting: DynamicProperty {
    @AppStorage(Appearance.storageKey) private var stored = Appearance.system
    @StateObject private var systemScheme = SystemSchemeObserver.shared

    var wrappedValue: Appearance {
        get { stored }
        nonmutating set { stored = newValue }
    }

    var projectedValue: AppearanceProjection {
        AppearanceProjection(
            binding: Binding(get: { stored }, set: { stored = $0 }),
            resolvedColorScheme: resolvedColorScheme
        )
    }

    /// Always-concrete value for `.preferredColorScheme`: the stored choice,
    /// or the observed system scheme for `.system`.
    var resolvedColorScheme: ColorScheme {
        switch wrappedValue {
        case .system: systemScheme.colorScheme
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Projected value of `AppearanceSetting`.
struct AppearanceProjection {
    var binding: Binding<Appearance>
    var resolvedColorScheme: ColorScheme
}
