import Foundation
import Testing

struct RenderDiagnosticsTests {
    @Test
    func manifestRoundTripsAndWritesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = RenderDiagnosticsManifest(
            runID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            stockID: "500T",
            iso: 500,
            environment: .init(
                operatingSystem: "test",
                target: "test",
                metalDevice: "test",
                metalRegistryID: 1,
                maxThreadsPerThreadgroup: [1, 1, 1]
            ),
            input: nil,
            output: nil,
            resources: []
        )

        try RenderDiagnostics.writeManifest(manifest, to: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RenderDiagnosticsManifest.self, from: data)
        #expect(decoded.runID == manifest.runID)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json.tmp").path))
    }

    @Test
    func missingMediaProducesRepresentativeFrameErrors() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let frames = await RenderDiagnostics.extractFrames(
            from: directory.appendingPathComponent("missing.mov"),
            directory: directory
        )
        #expect(frames.map(\.role) == ["start", "middle", "end"])
        #expect(frames.allSatisfy { $0.error != nil })
    }

    @Test
    func initialConfigurationFailurePreservesNonfiniteISO() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (iso, expected): (Float, String) in [(.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity")] {
            let error = RenderContractError.invalid(stockID: "500T", field: "ISO")
            let bundle = try #require(await RenderDiagnostics.writeInitialFailure(
                bundleDirectory: directory, inputURL: directory.appendingPathComponent("missing.mov"),
                stockID: "500T", iso: iso, stage: "configuration", error: error
            ))
            let data = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["iso"] as? String == expected)
            #expect(json["failureStage"] as? String == "configuration")
            #expect(json["succeeded"] as? Bool == false)
            #expect(json["error"] as? String == error.localizedDescription)
        }
    }

    @Test
    func recipeFailurePreservesNonfiniteSnapshotValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (iso, expected): (Float, String) in [(.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity")] {
            let config = FilmStockConfig(stockId: "500T", displayName: "500T", category: .video,
                lutName: "500T.cube", halationStrength: 0.2, glowStrength: 0.08,
                grainSize: 1.3, defaultISO: iso)
            #expect(throws: RenderContractError.self) { try config.validate() }
            var manifest = RenderDiagnosticsManifest(runID: UUID(), startedAt: Date(), stockID: config.stockId,
                iso: iso, environment: .init(operatingSystem: "test", target: "test", metalDevice: "test",
                    metalRegistryID: 0, maxThreadsPerThreadgroup: [1, 1, 1]), resources: [])
            manifest.recipe = .init(config: config, averageBitRate: RenderEncodingContract.averageBitRate,
                codec: RenderEncodingContract.codec)
            manifest.failureStage = "configuration"
            manifest.error = "Invalid ISO"
            try RenderDiagnostics.writeManifest(manifest, to: directory)
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let recipe = try #require(json["recipe"] as? [String: Any])
            let snapshot = try #require(recipe["config"] as? [String: Any])
            #expect(snapshot["defaultISO"] as? String == expected)
            #expect(json["iso"] as? String == expected)
            #expect(json["failureStage"] as? String == "configuration")
            #expect(json["succeeded"] as? Bool == false)
        }
    }

    @Test
    func stageErrorRetainsItsAttribution() {
        let error = RenderError.stageFailed("writer-append", "Writer rejected a frame.")
        #expect(error.stage == "writer-append")
        #expect(error.localizedDescription.contains("writer-append"))
    }
}
