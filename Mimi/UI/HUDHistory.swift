import Foundation

/// Pure HUD history-cycling semantics, extracted from `HUDView` for
/// testability. The HUD shows the newest translated entry unless a pin is
/// set; the history buttons step the pin older/newer.
enum HUDHistory {
    /// The sentence index to display: the pinned index while it still
    /// resolves in `entries` (a stale pin falls back to the newest entry),
    /// otherwise the newest entry. Nil when `entries` is empty.
    static func displayedIndex(in entries: [SessionEntry], pinned: Int?) -> Int? {
        guard let newest = entries.last?.sentence.index else { return nil }
        if let pinned, entries.contains(where: { $0.sentence.index == pinned }) {
            return pinned
        }
        return newest
    }

    /// Steps the pin `step` entries (-1 older, +1 newer) through `entries`,
    /// following the latest when no pin is set. Returns the new pin: nil
    /// re-follows latest (stepping onto the newest entry clears the pin);
    /// stepping past either end leaves the pin unchanged (clamped).
    static func cycle(entries: [SessionEntry], pinned: Int?, step: Int) -> Int? {
        guard let newest = entries.last?.sentence.index else { return pinned }
        let current = pinned ?? newest
        guard let at = entries.firstIndex(where: { $0.sentence.index == current }) else {
            return pinned
        }
        let next = at + step
        guard entries.indices.contains(next) else { return pinned }
        return next == entries.count - 1 ? nil : entries[next].sentence.index
    }

    /// "Newer" enablement: disabled at the latest entry (including when
    /// re-following latest), so the cursor follows new translations.
    static func canStepNewer(entries: [SessionEntry], pinned: Int?) -> Bool {
        guard let newest = entries.last?.sentence.index else { return false }
        return pinned != nil && pinned != newest
    }

    /// "Older" enablement: needs at least two entries and a pin above the
    /// oldest (no pin counts, since cycling pins to the previous entry).
    static func canStepOlder(entries: [SessionEntry], pinned: Int?) -> Bool {
        guard entries.count >= 2 else { return false }
        return pinned != entries[0].sentence.index
    }
}
