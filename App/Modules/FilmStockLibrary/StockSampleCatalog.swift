import Foundation

/// Offline, illustrative color previews. The manifest never promotes sample
/// photographs into camera-captured Log originals or a calibration claim.
struct StockSampleCatalog: Sendable {
    struct Scene: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let neutralFile: String
        let previews: [String: String]

        func imageURL(stockID: String?, directory: URL) -> URL? {
            let filename: String
            if let stockID {
                guard let preview = previews[stockID] else { return nil }
                filename = preview
            } else {
                filename = neutralFile
            }
            return directory.appendingPathComponent(filename)
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
        guard manifest.schemaVersion == 1, !manifest.scenes.isEmpty,
              !manifest.disclaimer.isEmpty,
              Set(manifest.scenes.map(\.id)).count == manifest.scenes.count else {
            throw CatalogError.invalidManifest
        }
        for scene in manifest.scenes {
            guard !scene.id.isEmpty, !scene.title.isEmpty, !scene.previews.isEmpty,
                  ([scene.neutralFile] + Array(scene.previews.values)).allSatisfy(isSafeFilename) else {
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
            for file in [scene.neutralFile] + Array(scene.previews.values) {
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
                    throw CatalogError.missingResources
                }
            }
        }
        return catalog
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        filename.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*\\.(jpg|jpeg|png)$",
                       options: .regularExpression) != nil
    }
}
