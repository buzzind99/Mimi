import Foundation

/// The pinned JMDict_Extended input. One release, never floating: the app
/// ships dictionary data derived from exactly this asset, and
/// `scripts/build_jmdict.sh` asserts its own copy of these constants matches
/// before doing any work — a pin bump must touch both or nothing builds.
enum JMDictPin {
    /// Full upstream release tag — never the date alone.
    static let releaseTag = "1.4.1-auto-release-2026-09-01"

    /// Upstream release asset this pin points at.
    static let sourceAssetFileName = "jmdictExtended-2026-09-01.json.zip"

    /// SHA-256 of the zipped asset, cross-checked against the digest GitHub
    /// publishes on the release asset at build time.
    static let sourceSHA256 = "4bee23eb7bd088d0a9c48301d0d25964b8ac9ecd6465c91b40adf8191d4b040a"

    /// Versioned artifact names derived from the tag. The tag is the
    /// staleness key: an app update shipping a new pin stages a new file and
    /// the stale one is simply inert.
    static let preparedFileName = "jmdict-\(releaseTag).sqlite"
    static let bundledFileName = preparedFileName + ".zst"
}
