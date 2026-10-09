import Foundation
import Testing
import AVFoundation

struct RenderContractTests {
    @Test func exportedMovieRetainsExactRenderSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, stockID) in ["kodak500t_f3513di", "kodak250d_f3513di"].enumerated() {
            let config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == stockID })
                .overridingISO(index == 0 ? 600 : 4900.5)
            let url = directory.appendingPathComponent("\(index).mov")
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            writer.metadata = try RenderMovieMetadata.make(config: config)
            // Tiny synthetic movie verifies metadata persistence, not Apple Log color accuracy.
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            writer.add(input)
            #expect(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            var pixelBuffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess)
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for _ in 0..<500 where !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(input.isReadyForMoreMediaData)
            #expect(adaptor.append(buffer, withPresentationTime: .zero))
            input.markAsFinished()
            await writer.finishWriting()
            try #require(writer.status == .completed)
            var values: [String: String] = [:]
            for item in try await AVURLAsset(url: url).load(.metadata) {
                if let key = item.key as? String, let value = try await item.load(.stringValue) { values[key] = value }
            }
            #expect(values["com.filmemulation.film-stock"] == config.stockId)
            #expect(values["com.filmemulation.iso"] == String(Int(config.defaultISO)))
            #expect(values["com.filmemulation.halation-level"] == String(config.halationStrength))
            #expect(values["com.filmemulation.iso-role"] == "selected-render-exposure-index")
            #expect(values["com.filmemulation.render-settings-schema"] == "1")
            let json = try #require(values["com.filmemulation.render-settings"])
            let snapshot = try JSONDecoder().decode(RenderDiagnosticsManifest.RecipeSnapshot.self, from: Data(json.utf8))
            #expect(snapshot.config == config)
            #expect(snapshot.effectiveRecipe == config.effectiveRecipe)
            #expect(snapshot.averageBitRate == 60_000_000)
            #expect(!snapshot.colorContractVerified)
        }
    }

    @Test func metadataReflectsBitrateOverride() throws {
        let config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak500t_k2383" })
        let items = try RenderMovieMetadata.make(config: config, bitrate: 80_000_000)
        var values: [String: String] = [:]
        for item in items {
            if let key = item.key as? String, let value = item.value as? String { values[key] = value }
        }
        #expect(values["com.filmemulation.encoding-bitrate-target"] == "80000000")
        let json = try #require(values["com.filmemulation.render-settings"])
        let snapshot = try JSONDecoder().decode(RenderDiagnosticsManifest.RecipeSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.averageBitRate == 80_000_000)
    }

    @Test func deliveryContractTagsSDRRec709() {
        #expect(RenderEncodingContract.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(RenderEncodingContract.transferFunction == AVVideoTransferFunction_ITU_R_709_2)
        #expect(RenderEncodingContract.yCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    struct Container: Decodable { let stocks: [FilmStockConfig] }
    private func stocks(_ path: String) throws -> [FilmStockConfig] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Container.self, from: Data(contentsOf: root.appendingPathComponent(path))).stocks
    }

    @Test func resourceParityAndEffectiveISO() throws {
        let app = try stocks("App/Resources/stocks.json")
        let cli = try stocks("Resources/stocks.json")
        #expect(app == cli)
        for config in app { try config.validate() }
        let template = try #require(app.first { $0.stockId == "kodak500t_f3513di" })
        #expect(template.grainSize == 1.3)
        let low = template.overridingISO(250)
        let high = template.overridingISO(1000)
        #expect(low.recipe == high.recipe)
        #expect(low.defaultISO == 250)
        #expect(high.defaultISO == 1000)
        #expect(high.overridingISO(template.defaultISO) == template)
        #expect(template.effectiveRecipe.input.transfer == "Apple Log 2")
        #expect(!template.effectiveRecipe.colorContractVerified)
    }

    @Test func outputContrastDecodesFromStockJSON() throws {
        // Regression: a `let`-declared property with a default value is silently
        // skipped by synthesized Codable (always returns the default). Contrast
        // must stay `var` so the stock's JSON value actually reaches the shader.
        let app = try stocks("App/Resources/stocks.json")
        let t500 = try #require(app.first { $0.stockId == "kodak500t_k2383" })
        #expect(t500.outputContrast == 0.6)
        #expect(t500.outputContrast != 1.0)
    }

    @Test func colorTemperatureDecodesPerStock() throws {
        // White balance is fixed per stock: daylight 5600K, tungsten 3200K.
        // 500T 85A = tungsten film shot through a daylight-converting 85A
        // filter, so it is balanced for daylight (5600K).
        let app = try stocks("App/Resources/stocks.json")
        func temp(_ id: String) throws -> Float {
            try #require(app.first { $0.stockId == id }).colorTemperature
        }
        #expect(try temp("kodak500t_k2383") == 3200)
        #expect(try temp("kodak500t_f3513di") == 3200)
        #expect(try temp("kodak200t_k2383") == 3200)
        #expect(try temp("kodak250d_k2383") == 5600)
        #expect(try temp("cinestill50d_k2383") == 5600)
        #expect(try temp("kodak500t85a_k2383") == 5600)
        // Tungsten stocks must NOT fall back to the daylight default (5600),
        // which would be the silent-failure mode of a `let`-declared property.
        #expect(try temp("kodak500t_k2383") != 5600)
    }

    @Test func recipeRoundTripAndRevisionEvidence() throws {
        var config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak500t_k2383" })
        let first = RenderDiagnosticsManifest.RecipeSnapshot(config: config, averageBitRate: RenderEncodingContract.averageBitRate, codec: RenderEncodingContract.codec)
        config.recipe?.version = "500t-current-v2"
        let second = RenderDiagnosticsManifest.RecipeSnapshot(config: config, averageBitRate: RenderEncodingContract.averageBitRate, codec: RenderEncodingContract.codec)
        let data = try JSONEncoder().encode(second)
        let decoded = try JSONDecoder().decode(RenderDiagnosticsManifest.RecipeSnapshot.self, from: data)
        #expect(first.effectiveRecipe.version != decoded.effectiveRecipe.version)
        #expect(first.config.lutName == decoded.config.lutName)
        #expect(decoded.config == config)
        #expect(decoded.averageBitRate == 60_000_000)
        #expect(decoded.codec == AVVideoCodecType.hevc.rawValue)
        #expect(!decoded.colorContractVerified)
        #expect(decoded.effectiveRecipe.output.transfer == "Rec.709")
        #expect(decoded.effectiveRecipe.output.gamut == "Rec.709")
        #expect(decoded.effectiveRecipe.output.provenance == "user-declared")
    }

    @Test func invalidParametersIdentifyTheStock() throws {
        let config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak500t_k2383" })
        for iso: Float in [.nan, .infinity, 0, -1] {
            do { try config.overridingISO(iso).validate(); Issue.record("Invalid ISO accepted") }
            catch { #expect(error.localizedDescription.contains(config.stockId)); #expect(error.localizedDescription.contains("ISO")) }
        }
        var invalid = config
        invalid.recipe?.schemaVersion = 99
        #expect(throws: RenderContractError.self) { try invalid.validate() }
        invalid = config
        invalid.recipe?.domainMax = [.nan, 1, 1]
        #expect(throws: RenderContractError.self) { try invalid.validate() }
        invalid = config
        invalid.recipe?.grainAlgorithm = "unknown"
        #expect(throws: RenderContractError.self) { try invalid.validate() }
        for field in ["halationStrength", "glowStrength", "grainSize"] {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
            object[field] = -1
            let bad = try JSONDecoder().decode(FilmStockConfig.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: RenderContractError.self) { try bad.validate() }
        }
    }

    @Test func missingRecipeDoesNotInventProvenance() throws {
        var config = try #require(stocks("App/Resources/stocks.json").first)
        config.recipe = nil
        let decoded = try JSONDecoder().decode(FilmStockConfig.self, from: JSONEncoder().encode(config))
        try decoded.validate()
        #expect(decoded.recipe == nil)
        #expect(decoded.effectiveRecipe.input.transfer == "unverified")
        #expect(!decoded.effectiveRecipe.colorContractVerified)
    }
}
