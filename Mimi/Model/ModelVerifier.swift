import CryptoKit
import Foundation
import Synchronization

/// Pinned-digest verification for the ASR GGUFs. Positive verdicts are cached
/// at two tiers so the multi-hundred-MB re-hash only runs when a file actually
/// changes (first resolve, re-download, or a dropped-in replacement): an
/// in-process hot set, and a store persisted to disk (`VerdictStore`) so
/// relaunches skip re-hashing too. Both key on (path, size, modification
/// date), so both choices coexist and any size or mtime change invalidates
/// the verdict and forces a re-hash.
///
/// Residual risk (accepted; same trust model as `ModelDownloader`, which
/// trusts the file at the well-known path after download-time verification)
enum ModelVerifier {
    /// Pinned SHA-256 for the choice's GGUF (release-time integrity check).
    static func expectedSHA256(for choice: ASRModelChoice) -> String {
        choice.pinnedSHA256
    }

    struct VerificationError: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    /// Cache key for a positive verdict. `modified` is rounded to whole
    /// microseconds so the persisted form (a JSON Double) round-trips exactly:
    /// microsecond-scale integers stay below 2^53, making the encoded value
    /// bit-stable across save/load — a raw nanosecond timestamp would risk a
    /// spurious mismatch on every relaunch.
    struct CacheKey: Hashable {
        let path: String
        let size: Int64
        let modified: Date

        init(path: String, size: Int64, modified: Date) {
            self.path = path
            self.size = size
            let microseconds = (modified.timeIntervalSinceReferenceDate * 1_000_000).rounded()
            self.modified = Date(timeIntervalSinceReferenceDate: microseconds / 1_000_000)
        }
    }

    /// One persisted verdict: the file attributes whose exact match allows
    /// trusting the recorded digest without a re-hash.
    struct VerdictStoreEntry: Codable {
        let size: Int64
        let mtime: Date
    }

    /// Per-store mutable state, guarded by the store's `Mutex`.
    private struct VerdictStoreState {
        var entries: [String: VerdictStoreEntry] = [:]
        var loaded = false
        /// In-process hot set — checked before the (lazily loaded)
        /// persisted entries.
        var hot: Set<CacheKey> = []
    }

    /// Persisted positive-verdict store: `path → (size, mtime)` as JSON at a
    /// well-known Application Support location. Owns both cache tiers for its
    /// location — the in-process hot set and the persisted entries — so one
    /// shared instance serves production and a fresh instance on the same URL
    /// cleanly simulates a relaunch. Loaded lazily on first use and rewritten
    /// atomically on each `record` (records are rare — once per model-file
    /// lifetime). A missing or corrupt store degrades to "nothing persisted"
    /// (fail-soft); in-memory caching is unaffected.
    final class VerdictStore: Sendable {
        /// Production location: `~/Library/Application Support/Mimi/
        /// verification-cache.json` (sibling of the models directory).
        static let shared = VerdictStore(url: {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("Mimi/verification-cache.json")
        }())

        let url: URL
        private let state = Mutex(VerdictStoreState())

        init(url: URL) {
            self.url = url
        }

        /// True iff the file matches the choice's pinned SHA-256, consulting
        /// the hot set and the persisted entries before hashing. Only positive
        /// verdicts are cached.
        func isVerified(_ file: URL, for choice: ASRModelChoice) -> Bool {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let size = attrs[.size] as? Int64,
                  let modified = attrs[.modificationDate] as? Date
            else { return false }
            let key = CacheKey(path: file.path, size: size, modified: modified)
            if state.withLock({ $0.hot.contains(key) }) {
                return true
            }
            if contains(key) {
                // Persisted hit: promote to the hot set.
                state.withLock { _ = $0.hot.insert(key) }
                return true
            }
            do {
                try ModelVerifier.verify(file, for: choice)
            } catch {
                return false
            }
            state.withLock { _ = $0.hot.insert(key) }
            record(key)
            return true
        }

        /// True when the store holds a verdict for exactly this key
        /// (path, size, and modification date all match).
        func contains(_ key: CacheKey) -> Bool {
            state.withLock { state in
                loadIfNeeded(&state)
                guard let verdict = state.entries[key.path] else { return false }
                return verdict.size == key.size && verdict.mtime == key.modified
            }
        }

        /// Records a successful verification, overwriting any prior verdict
        /// for the same path and persisting the store.
        func record(_ key: CacheKey) {
            state.withLock { state in
                loadIfNeeded(&state)
                state.entries[key.path] = VerdictStoreEntry(size: key.size, mtime: key.modified)
                save(&state)
            }
        }

        private func loadIfNeeded(_ state: inout VerdictStoreState) {
            guard !state.loaded else { return }
            state.loaded = true
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([String: VerdictStoreEntry].self, from: data)
            else { return }
            state.entries = decoded
        }

        private func save(_ state: inout VerdictStoreState) {
            guard let data = try? JSONEncoder().encode(state.entries) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Returns true iff the file matches the choice's pinned SHA-256,
    /// delegating to the store's two-tier cache. `store` is injectable so
    /// tests never touch the real Application Support location.
    static func isVerified(
        _ file: URL, for choice: ASRModelChoice, store: VerdictStore = .shared
    ) -> Bool {
        store.isVerified(file, for: choice)
    }

    static func verify(_ file: URL, for choice: ASRModelChoice) throws(VerificationError) {
        let digest: SHA256Digest
        do {
            digest = try SHA256.digest(file: file)
        } catch {
            // The digest helper's failures are plain file-I/O errors; they
            // surface here as verification failures with the cause attached.
            throw VerificationError(
                message: "model file could not be read for verification: \(error.localizedDescription)"
            )
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if hex != expectedSHA256(for: choice).lowercased() {
            throw VerificationError(
                message: "model file does not match Mimi's pinned checksum — "
                    + "delete it and re-download, or replace it with an authentic copy"
            )
        }
    }
}

private extension SHA256 {
    static func digest(file: URL) throws -> SHA256Digest {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
    }
}
