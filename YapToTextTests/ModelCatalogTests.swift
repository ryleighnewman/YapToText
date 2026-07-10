import XCTest
@testable import YapToText

final class ModelCatalogTests: XCTestCase {
    func testIDsAreUnique() {
        let ids = ModelCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testBuiltInsPresentAndWellFormed() {
        for id in ["apple", "apple-foundation"] {
            guard let model = ModelCatalog.all.first(where: { $0.id == id }) else {
                return XCTFail("Missing built-in \(id)")
            }
            XCTAssertEqual(model.runtime, .apple)
            XCTAssertEqual(model.sizeMB, 0)
            XCTAssertNil(model.downloadURL)
            XCTAssertNil(model.fileName)
            XCTAssertTrue(model.isBuiltIn)
        }
    }

    func testDownloadableEntriesAreWellFormed() {
        for model in ModelCatalog.all where !model.isBuiltIn {
            XCTAssertNotNil(model.downloadURL, "\(model.id) missing downloadURL")
            XCTAssertFalse((model.fileName ?? "").isEmpty, "\(model.id) missing fileName")
            XCTAssertGreaterThan(model.sizeMB, 0, "\(model.id) has no size")
            XCTAssertTrue((1...5).contains(model.quality), "\(model.id) quality out of range")
        }
    }

    func testWhisperURLsPointAtHuggingFaceAndContainFile() {
        for model in ModelCatalog.all where model.runtime == .whisperCpp {
            XCTAssertEqual(model.downloadURL?.host, "huggingface.co")
            XCTAssertTrue(model.downloadURL?.absoluteString.contains(model.fileName ?? "?") ?? false)
        }
    }

    func testCatalogHasBothKinds() {
        XCTAssertTrue(ModelCatalog.all.contains { $0.kind == .speech })
        XCTAssertTrue(ModelCatalog.all.contains { $0.kind == .language })
    }

    func testSizeDescription() {
        func size(_ mb: Double) -> String {
            ModelInfo(id: "t", displayName: "t", provider: "p", kind: .speech, summary: "",
                      languages: "", sizeMB: mb, quality: 3, downloadURL: nil, fileName: nil,
                      runtime: .apple, license: "").sizeDescription
        }
        XCTAssertEqual(size(0), "Built-in")
        XCTAssertEqual(size(574), "574 MB")
        XCTAssertEqual(size(1560), "1.5 GB")
    }
}
