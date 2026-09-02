import CryptoKit
import Foundation

/// Pinned-digest verification for the ASR GGUF. Verdicts are cached per
/// (path, size) so the ~200 MB re-hash only runs when the file actually
/// changes (first resolve, re-download, or a dropped-in replacement).
enum ModelVerifier {
    /// Pinned SHA-256 of the q8_0 GGUF (release-time integrity check).
    static let expectedSHA256 =
        "f547589d5ca582e093b2d3312ad9ff13b609b43d413f972c0e92b823dde70a00"

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

    private static let lock = NSLock()
    private static var verified: Set<CacheKey> = []

    /// Returns true iff the file matches the pinned SHA-256.
    static func isVerified(_ file: URL) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int64
        else { return false }
        let key = CacheKey(path: file.path, size: size)
        if lock.withLock({ verified.contains(key) }) {
            return true
        }
        do {
            try verify(file)
        } catch {
            return false
        }
        lock.withLock { verified.insert(key) }
        return true
    }

    static func verify(_ file: URL) throws {
        let digest = try SHA256.digest(file: file)
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
