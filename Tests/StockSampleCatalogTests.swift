import Foundation
import Testing

struct StockSampleCatalogTests {
    @Test func selectedStockResolvesItsOwnPreviewWithoutChangingTheScene() throws {
        let catalog = try decode()
        let scene = try #require(catalog.scenes.first)
        #expect(scene.imageURL(stockID: "kodak5207", directory: catalog.directory)?.lastPathComponent
                == "daylight-kodak5207.jpg")
        #expect(scene.imageURL(stockID: "kodak5219", directory: catalog.directory)?.lastPathComponent
                == "daylight-kodak5219.jpg")
        #expect(scene.imageURL(stockID: nil, directory: catalog.directory)?.lastPathComponent
                == "daylight-neutral.jpg")
        #expect(scene.id == "daylight")
    }

    @Test func anUnknownStockMustNotBeMisrepresentedByTheNeutralImage() throws {
        let catalog = try decode()
        #expect(catalog.scenes.first?.imageURL(stockID: "unknown", directory: catalog.directory) == nil)
    }

    @Test(arguments: ["../outside.jpg", "/private/example.jpg", "sub/image.jpg", "a\\b.jpg", ".jpg"])
    func resourcePathsCannotEscapeTheSampleFolder(_ filename: String) throws {
        #expect(throws: (any Error).self) { try decode(neutral: filename) }
    }

    @Test func unsupportedSchemasAndDuplicateSceneIDsFailClosed() throws {
        #expect(throws: (any Error).self) { try decode(schema: 2) }
        #expect(throws: (any Error).self) { try decode(duplicate: true) }
    }

    private func decode(neutral: String = "daylight-neutral.jpg", schema: Int = 1,
                        duplicate: Bool = false) throws -> StockSampleCatalog {
        let scene: [String: Any] = [
            "id": "daylight", "title": "Daylight", "neutralFile": neutral,
            "previews": ["kodak5207": "daylight-kodak5207.jpg", "kodak5219": "daylight-kodak5219.jpg"]
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schema, "disclaimer": "Illustrative photos · color LUT only",
            "scenes": duplicate ? [scene, scene] : [scene]
        ])
        return try StockSampleCatalog.decode(data, directory: URL(fileURLWithPath: "/samples"))
    }
}
