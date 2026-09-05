import AppKit
import Foundation

/// Export surface of `AppModel` (plain-text copy + the four file formats
/// behind the export menu), split out to keep the main file focused on
/// session lifecycle.
extension AppModel {
    var isExportable: Bool {
        !entries.isEmpty
    }

    func exportText() -> String {
        SessionExporter.plainText(entries: entries)
    }

    /// Copies the plain-text transcript to the pasteboard; shared by the
    /// ⌘⇧C command and the export menu.
    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText(), forType: .string)
    }

    func export(format: SessionExporter.Format) throws -> Data {
        switch format {
        case .txt:
            return Data(SessionExporter.plainText(entries: entries).utf8)
        case .srt:
            return Data(SessionExporter.subtitles(entries: entries, format: .srt).utf8)
        case .vtt:
            return Data(SessionExporter.subtitles(entries: entries, format: .vtt).utf8)
        case .json:
            let results = snapshotTranslationResults()
            return try SessionExporter.json(
                entries: entries, metadata: sessionController.sessionMetadata, results: results
            )
        }
    }

    private func snapshotTranslationResults() -> [Int: SentenceTranslation] {
        var snapshot: [Int: SentenceTranslation] = [:]
        for entry in entries {
            if let translation = entry.translations.last {
                snapshot[entry.sentence.index] = translation
            }
        }
        return snapshot
    }
}
