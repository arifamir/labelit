import Foundation
import Testing
@testable import LabelItEmbedding
@testable import LabelItCore

@Suite struct DescriberLogicTests {
    @Test func redundantWords() {
        #expect(GemmaPhotoDescriber.isRedundant("snowy", after: ["snow"]))
        #expect(GemmaPhotoDescriber.isRedundant("garden", after: ["garden"]))
        #expect(!GemmaPhotoDescriber.isRedundant("beach", after: ["dog"]))
        #expect(!GemmaPhotoDescriber.isRedundant("car-wheel", after: ["car-interior"]))
    }

    @Test func imageSizeFillsTheBudgetInMultiplesOf48() throws {
        let size = try #require(GemmaEmbedder.targetSize(height: 3024, width: 4032, budget: 280))
        #expect(size.height % 48 == 0 && size.width % 48 == 0)
        #expect((size.height / 48) * (size.width / 48) <= 280)
        #expect(size.width > size.height)
    }

    @Test func vocabularyHasNoDuplicates() {
        for (_, concepts) in Vocabulary.groups {
            #expect(Set(concepts.map(\.slug)).count == concepts.count)
        }
    }
}

@Suite struct HashingTests {
    /// The portable SHA-256 (Linux, Windows) against known answers, including a multi-block input.
    @Test func portableSHA256MatchesTheStandard() {
        func hash(_ text: String) -> String {
            var hasher = PortableSHA256()
            hasher.update(Data(text.utf8))
            return hasher.hexDigest()
        }
        #expect(hash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        let million = String(repeating: "a", count: 1_000_000)
        #expect(hash(million) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        #expect(Hashing.sha256Hex(Data("abc".utf8)) == hash("abc"))
    }
}

/// Runs the real model when it's on this Mac (DigUp's or LabelIt's download); skipped otherwise.
@Suite(.serialized, .enabled(if: ModelFiles.locate() != nil)) struct ModelTests {
    @Test func textAndImageShareASpace() async throws {
        let files = try #require(ModelFiles.locate())
        let embedder = try GemmaEmbedder(files: files)
        defer { embedder.close() }
        let texts = try embedder.embed(texts: ["task: search result | query: a photo of a red circle",
                                               "task: search result | query: a photo of a mountain lake"])
        #expect(texts.count == 2 && texts[0].count == 768)
        let image = try #require(Self.redCircle())
        let vector = try embedder.embed(image: image)
        #expect(dot(vector, texts[0]) > dot(vector, texts[1]))
    }

    /// A red disc on white, drawn in plain Swift so the test runs on every platform.
    static func redCircle() -> RGBPicture? {
        let size = 600
        var pixels = [UInt8](repeating: 255, count: size * size * 3)
        for y in 0..<size {
            for x in 0..<size where (x - 300) * (x - 300) + (y - 300) * (y - 300) <= 200 * 200 {
                let i = (y * size + x) * 3
                (pixels[i], pixels[i + 1], pixels[i + 2]) = (230, 26, 26)
            }
        }
        return RGBPicture(width: size, height: size, pixels: pixels)
    }
}
