import Foundation

/// A unique scratch directory that removes itself on `deinit`. Replaces the
/// setUp/tearDown tmpdir boilerplate in the Model/ASR suites: declare it as a
/// suite property (Swift Testing instantiates the suite fresh per test, so
/// every test gets its own directory) or keep a local alive for the test
/// body — removal happens when the instance goes away, so hold the reference
/// for as long as the files are needed.
final class TemporaryDirectory {

    /// Root of the directory — append names to address entries inside it.
    let url: URL

    /// Creates `<prefix>-<UUID>/` under the user temp directory.
    init(prefix: String = "mimi-tests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// URL of a named entry inside the directory (does not create it).
    func fileURL(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Writes data to a named file inside the directory; returns its URL.
    @discardableResult
    func write(_ data: Data, named name: String) throws -> URL {
        let fileURL = fileURL(name)
        try data.write(to: fileURL)
        return fileURL
    }
}
