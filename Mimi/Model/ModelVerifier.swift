import CryptoKit
import Foundation
import Synchronization

/// Pinned-digest verification for the ASR GGUFs. Verdicts are cached per
/// (path, size) so the multi-hundred-MB re-hash only runs when a file
/// actually changes (first resolve, re-download, or a dropped-in
/// replacement); the cache keys on the path, so both choices can coexist.
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

    private struct CacheKey: Hashable {
        let path: String
        let size: Int64
    }

    /// Verdicts are inserted only after `verify` succeeds.
    private static let verified = Mutex<Set<CacheKey>>([])

    /// Returns true iff the file matches the choice's pinned SHA-256.
    static func isVerified(_ file: URL, for choice: ASRModelChoice) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int64
        else { return false }
        let key = CacheKey(path: file.path, size: size)
        if verified.withLock({ $0.contains(key) }) {
            return true
        }
        do {
            try verify(file, for: choice)
        } catch {
            return false
        }
        verified.withLock { _ = $0.insert(key) }
        return true
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
