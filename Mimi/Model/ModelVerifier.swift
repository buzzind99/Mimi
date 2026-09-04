import CryptoKit
import Foundation
import Synchronization

/// Pinned-digest verification for the ASR GGUF. Verdicts are cached per
/// (path, size) so the ~600 MB re-hash only runs when the file actually
/// changes (first resolve, re-download, or a dropped-in replacement).
enum ModelVerifier {
    /// Pinned SHA-256 of the q8_0 GGUF (release-time integrity check).
    static let expectedSHA256 =
        "dac5e1b95659c0a95b2a1dc60083eb17740454a921ec39f9c24e50b930ca31ab"

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

    /// Returns true iff the file matches the pinned SHA-256.
    static func isVerified(_ file: URL) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int64
        else { return false }
        let key = CacheKey(path: file.path, size: size)
        if verified.withLock({ $0.contains(key) }) {
            return true
        }
        do {
            try verify(file)
        } catch {
            return false
        }
        verified.withLock { _ = $0.insert(key) }
        return true
    }

    static func verify(_ file: URL) throws(VerificationError) {
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
        if hex != expectedSHA256.lowercased() {
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
