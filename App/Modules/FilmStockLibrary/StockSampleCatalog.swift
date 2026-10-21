import Foundation

/// The bundled preview plates: one Apple Log 2 still per scene, shipped ungraded so the
/// app applies the selected stock's LUT (and later grain, halation and glow) at display
/// time. The manifest never promotes these into camera-captured originals or a calibration
/// claim.
struct StockSampleCatalog: Sendable {
    struct Scene: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        /// Apple Log 2 encoded plate, LUT applied live by `PlateLUTRenderer`.
        let plate: String

        func plateURL(directory: URL) -> URL {
            directory.appendingPathComponent(plate)
        }
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let disclaimer: String
        let scenes: [Scene]
    }

    enum CatalogError: Error {
        case missingResources
        case invalidManifest
    }

    let directory: URL
    let disclaimer: String
    let scenes: [Scene]

    static func decode(_ data: Data, directory: URL) throws -> Self {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 2, !manifest.scenes.isEmpty,
              !manifest.disclaimer.isEmpty,
              Set(manifest.scenes.map(\.id)).count == manifest.scenes.count else {
            throw CatalogError.invalidManifest
        }
        for scene in manifest.scenes {
            guard !scene.id.isEmpty, !scene.title.isEmpty,
                  isSafeFilename(scene.plate) else {
                throw CatalogError.invalidManifest
            }
        }
        return Self(directory: directory, disclaimer: manifest.disclaimer, scenes: manifest.scenes)
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let directory = bundle.url(forResource: "StockSamples", withExtension: nil) else {
            throw CatalogError.missingResources
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let catalog = try decode(data, directory: directory)
        for scene in catalog.scenes {
            guard FileManager.default.fileExists(atPath: scene.plateURL(directory: directory).path) else {
                throw CatalogError.missingResources
            }
        }
        return catalog
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        filename.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*\\.(jpg|jpeg|png)$",
                       options: .regularExpression) != nil
    }
}
