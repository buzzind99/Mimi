import Foundation
@testable import Mimi

/// The live dictionary runtime shared by the live test suites (engine and
/// annotator corpus): one `DictionaryEngine` over the store's prepared
/// dictionary when one resolves (first launch, `MIMI_DICT`, or the
/// dev-checkout `models/ipadic.dic`), else the script-fetched model
/// decompressed once into a private temp file. nil when the dylib or a
/// dictionary is unavailable — live suites disable themselves.
///
/// The single shared handle matters beyond convenience: the dictionary is
/// loaded per engine, and the engine suite's leak test measures a
/// process-wide footprint — a second concurrent load would pollute it.
enum LiveDictionaryRuntime {
    static let engine: DictionaryEngine? = {
        guard let ffi = DictionaryFFI.load() else { return nil }
        if let resolved = DictionaryStore.resolve() {
            return DictionaryEngine(ffi: ffi, resolveDictionary: { resolved })
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = repoRoot.appendingPathComponent(
            "local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst"
        )
        guard FileManager.default.fileExists(atPath: model.path) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-dictengine-live.ipadic.dic")
        guard ffi.prepare(model.path, destination.path) == 0 else { return nil }
        return DictionaryEngine(ffi: ffi, resolveDictionary: { destination })
    }()

    static var isAvailable: Bool {
        engine != nil
    }
}
