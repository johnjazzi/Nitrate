import Foundation
import Testing

struct StockSampleCatalogTests {
    @Test func everySceneResolvesItsBundledPlate() throws {
        let catalog = try decode()
        let scene = try #require(catalog.scenes.first)
        #expect(scene.plateURL(directory: catalog.directory).lastPathComponent == "neon-log.jpg")
        #expect(scene.id == "neon")
    }

    @Test func theManifestIsThePlateSchemaNotTheGradedOne() throws {
        // Schema 1 shipped per-stock graded stills. A stale manifest must fail closed rather
        // than leave the selector showing nothing.
        #expect(throws: (any Error).self) { try decode(schema: 1) }
        #expect(throws: (any Error).self) { try decode(plate: "") }
    }

    @Test(arguments: ["../outside.jpg", "/private/example.jpg", "sub/image.jpg", "a\\b.jpg", ".jpg"])
    func resourcePathsCannotEscapeTheSampleFolder(_ filename: String) throws {
        #expect(throws: (any Error).self) { try decode(plate: filename) }
    }

    @Test func aSceneWithoutAnAssumedIlluminantFallsBackToDaylight() throws {
        // Older manifests predate the field; the preview must still show something sane
        // rather than a black plate from an unset gain.
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "disclaimer": "Illustrative",
            "scenes": [["id": "neon", "title": "Neon", "plate": "neon-log.jpg",
                        "derivation": [:]]],
        ])
        let catalog = try StockSampleCatalog.decode(data, directory: URL(fileURLWithPath: "/samples"))
        #expect(catalog.scenes.first?.sceneIlluminantKelvin == 5600)
    }

    @Test func duplicateSceneIDsFailClosed() throws {
        #expect(throws: (any Error).self) { try decode(duplicate: true) }
    }

    private func decode(schema: Int = 2, plate: String = "neon-log.jpg",
                        duplicate: Bool = false) throws -> StockSampleCatalog {
        let scene: [String: Any] = ["id": "neon", "title": "Neon", "plate": plate,
                                    "derivation": ["sceneIlluminantKelvin": 5600]]
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schema,
            "disclaimer": "Illustrative plates \u{00b7} your LUT applied live",
            "scenes": duplicate ? [scene, scene] : [scene],
        ])
        return try StockSampleCatalog.decode(data, directory: URL(fileURLWithPath: "/samples"))
    }
}
