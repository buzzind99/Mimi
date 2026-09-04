import Foundation
@testable import Mimi
import Testing

@Suite("ASRModelChoice")
struct ASRModelChoiceTests {
    @Test("every choice exposes complete display and download metadata")
    func metadataPerChoice() {
        for choice in ASRModelChoice.allCases {
            #expect(choice.id == choice.rawValue)
            #expect(!choice.displayName.isEmpty)
            #expect(!choice.approximateSize.isEmpty)
            #expect(!choice.blurb.isEmpty)
            #expect(choice.pinnedSHA256.count == 64)
            #expect(choice.downloadURL.lastPathComponent == choice.ggufFileName)
            #expect(choice.downloadURL.path.contains(choice.modelID))
        }

        #expect(ASRModelChoice.lite.displayName == "Lite")
        #expect(ASRModelChoice.full.displayName == "Full")
        #expect(ASRModelChoice.lite.approximateSize != ASRModelChoice.full.approximateSize)
        #expect(ASRModelChoice.lite.blurb != ASRModelChoice.full.blurb)
        #expect(ASRModelChoice.lite.ggufFileName != ASRModelChoice.full.ggufFileName)
        #expect(ASRModelChoice.lite.modelID != ASRModelChoice.full.modelID)
        #expect(ASRModelChoice.lite.downloadURL != ASRModelChoice.full.downloadURL)
        #expect(ASRModelChoice.lite.pinnedSHA256 != ASRModelChoice.full.pinnedSHA256)
    }

    @Test("the two choices stay mutually distinct")
    func allCasesAreDistinct() {
        #expect(ASRModelChoice.allCases == [.lite, .full])
    }
}
