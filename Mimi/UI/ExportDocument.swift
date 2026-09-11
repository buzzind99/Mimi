import SwiftUI
import UniformTypeIdentifiers

/// Minimal `FileDocument` wrapper that hands the prepared export payload to
/// SwiftUI's `fileExporter`.
struct ExportDocument: FileDocument {
    let data: Data

    static var readableContentTypes: [UTType] {
        []
    }

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
