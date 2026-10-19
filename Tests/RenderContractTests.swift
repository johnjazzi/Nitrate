import Foundation
import Testing
import AVFoundation

struct RenderContractTests {
    @Test func consumerMetadataUsesConciseNitrateCaption() throws {
        let stock = FilmStockConfig(stockId: "test", displayName: "Kodak 5219", category: .video,
            lutName: "test.cube", halationStrength: 0, glowStrength: 0, grainSize: 1, defaultISO: 600)
        for gauge in PrintGauge.allCases {
            let config = stock.overridingGauge(gauge)
            let items = try RenderMovieMetadata.make(config: config, bitrate: 80_000_000)
            let caption = "nitrate: Kodak 5219 | \(gauge.rawValue)"
            for key in [AVMetadataKey.commonKeyTitle, .commonKeyDescription] {
                let item = try #require(items.first { $0.commonKey == key })
                #expect(item.value as? String == caption)
            }
            #expect(items.first { ($0.key as? String) == "com.filmemulation.iso" }?.value as? String == "600")
            #expect(items.first { ($0.key as? String) == "com.filmemulation.print-gauge" }?.value as? String == gauge.rawValue)
        }
    }

    @Test func sourceColorContractRequiresAppleLog2Identifier() throws {
        func evidence(primaries: String? = nil, transfer: String? = nil,
                      matrix: String? = AVVideoYCbCrMatrix_ITU_R_2020 as String) -> RenderInputColorProvenance.FormatEvidence {
            .init(logTransferFunction: "com.apple.apple-wide-gamut.apple-log", colorPrimaries: primaries,
                  transferFunction: transfer, yCbCrMatrix: matrix, bitDepth: "10")
        }

        // The SDK defines Apple Log 2 primaries and ordinary transfer tags as
        // undefined or absent; it exports no separate undefined-value constant.
        let undefinedStandardTags = evidence()
        try RenderInputColorProvenance.validate([undefinedStandardTags])

        let appleLog = RenderInputColorProvenance.FormatEvidence(
            logTransferFunction: "com.apple.rec2020.apple-log", colorPrimaries: nil,
            transferFunction: nil, yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020 as String, bitDepth: "10"
        )
        #expect(throws: RenderInputColorContractError.self) { try RenderInputColorProvenance.validate([appleLog]) }
        #expect(throws: RenderInputColorContractError.self) { try RenderInputColorProvenance.validate([]) }

        let incompatibleTags = [
            evidence(transfer: AVVideoTransferFunction_ITU_R_709_2 as String),
            evidence(transfer: AVVideoTransferFunction_Linear as String),
            evidence(transfer: AVVideoTransferFunction_SMPTE_ST_2084_PQ as String),
            evidence(transfer: AVVideoTransferFunction_ITU_R_2100_HLG as String),
            evidence(primaries: AVVideoColorPrimaries_ITU_R_2020 as String),
            evidence(primaries: AVVideoColorPrimaries_P3_D65 as String),
            evidence(primaries: "unknown-primaries"),
            evidence(transfer: "unknown-transfer"),
            evidence(matrix: AVVideoYCbCrMatrix_ITU_R_709_2 as String),
            evidence(matrix: nil),
            evidence(matrix: "unknown-matrix")
        ]
        for incompatible in incompatibleTags {
            #expect(throws: RenderInputColorContractError.self) {
                try RenderInputColorProvenance.validate([incompatible])
            }
        }
        #expect(throws: RenderInputColorContractError.self) {
            try RenderInputColorProvenance.validate([undefinedStandardTags, appleLog])
        }
    }

    @Test func exportedMovieRetainsExactRenderSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, stockID) in ["kodak5219", "kodak5207"].enumerated() {
            let config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == stockID })
                .overridingISO(index == 0 ? 600 : 4900.5)
            let url = directory.appendingPathComponent("\(index).mov")
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            let syntheticProvenance = RenderInputColorProvenance.syntheticTestBypass([])
            writer.metadata = try RenderMovieMetadata.make(config: config, sourceColorProvenance: syntheticProvenance)
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
            // Daylight/tungsten tag travels with the render.
            #expect(values["com.filmemulation.light-type"] == config.lightType)
            #expect(values["com.filmemulation.iso"] == String(Int(config.defaultISO)))
            #expect(values["com.filmemulation.halation-level"] == String(config.halationStrength))
            #expect(values["com.filmemulation.iso-role"] == "selected-render-exposure-index")
            #expect(values["com.filmemulation.shutter-speed"] == "1/48")
            #expect(values["com.filmemulation.shutter-angle"] == "180")
            #expect(values["com.filmemulation.grain-algorithm"] == config.effectiveRecipe.grainAlgorithm)
            #expect(values["com.filmemulation.grain-edge-boost-multiplier"] == String(config.effectiveRecipe.edgeBoostMultiplier))
            #expect(values["com.filmemulation.render-settings-schema"] == "1")
            let json = try #require(values["com.filmemulation.render-settings"])
            let snapshot = try JSONDecoder().decode(RenderDiagnosticsManifest.RecipeSnapshot.self, from: Data(json.utf8))
            #expect(snapshot.config == config)
            #expect(snapshot.effectiveRecipe == config.effectiveRecipe)
            #expect(snapshot.averageBitRate == 60_000_000)
            #expect(!snapshot.colorContractVerified)
            #expect(snapshot.sourceColorProvenance == syntheticProvenance)
            #expect(values["com.filmemulation.source-color-test-bypass"] == "true")
        }
    }

    @Test func metadataReflectsBitrateOverride() throws {
        let config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak5219" })
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

    @Test func metadataDocumentsFilmShutterContract() throws {
        let config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak5219" })
        let items = try RenderMovieMetadata.make(config: config)
        var values: [String: String] = [:]
        for item in items {
            if let key = item.key as? String, let value = item.value as? String { values[key] = value }
        }
        #expect(values["com.filmemulation.shutter-speed"] == "1/48")
        #expect(values["com.filmemulation.shutter-angle"] == "180")
        #expect(values["com.filmemulation.grain-algorithm"] == config.effectiveRecipe.grainAlgorithm)
        #expect(values["com.filmemulation.grain-edge-boost-multiplier"] == String(config.effectiveRecipe.edgeBoostMultiplier))
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
        let shippedGrainStocks = app.filter {
            ["kodak5207", "kodak5219"].contains($0.stockId)
        }
        #expect(shippedGrainStocks.count == 2)
        #expect(shippedGrainStocks.allSatisfy { $0.effectiveRecipe.grainAlgorithm == RenderRecipe.edgeAmplitudeAlgorithm })
        #expect(shippedGrainStocks.allSatisfy { $0.effectiveRecipe.edgeBoostMultiplier == 3 })
        let template = try #require(app.first { $0.stockId == "kodak5219" })
        #expect(template.grainSize == 1.3)
        #expect(template.effectiveRecipe.version == "5219-current-v11")
        #expect(template.effectiveRecipe.grainAlgorithm == RenderRecipe.edgeAmplitudeAlgorithm)
        #expect(template.effectiveRecipe.edgeBoostMultiplier == 3)
        let low = template.overridingISO(250)
        let high = template.overridingISO(1000)
        #expect(low.recipe == high.recipe)
        #expect(low.defaultISO == 250)
        #expect(high.defaultISO == 1000)
        #expect(high.overridingISO(template.defaultISO) == template)
        #expect(template.effectiveRecipe.input.transfer == "Apple Log 2")
        #expect(!template.effectiveRecipe.colorContractVerified)
    }

    @Test func shippedHalationTuningPreservesGlowGrainAndContrast() throws {
        for path in ["App/Resources/stocks.json", "Resources/stocks.json"] {
            let catalog = try stocks(path)
            let daylight = try #require(catalog.first { $0.stockId == "kodak5207" })
            let tungsten = try #require(catalog.first { $0.stockId == "kodak5219" })
            #expect(daylight.glowStrength == 0.155)
            #expect(tungsten.glowStrength == 0.2325)
            #expect(daylight.halationStrength == 5)
            #expect(tungsten.halationStrength == 5)
            #expect(daylight.grainSize == 1.15)
            #expect(tungsten.grainSize == 1.3)
            #expect(daylight.outputContrast == 0.85)
            #expect(tungsten.outputContrast == 0.85)
            #expect(daylight.effectiveRecipe.version == "5207-current-v6")
            #expect(tungsten.effectiveRecipe.version == "5219-current-v11")
        }
    }

    @Test func shippedContrastIsFifteenPercentLowerAndHistoricalExplicitContrastStillDecodes() throws {
        let app = try stocks("App/Resources/stocks.json")
        for path in ["App/Resources/stocks.json", "Resources/stocks.json"] {
            let catalog = try stocks(path)
            let daylight = try #require(catalog.first { $0.stockId == "kodak5207" })
            let tungsten = try #require(catalog.first { $0.stockId == "kodak5219" })
            #expect(daylight.outputContrast == 0.85)
            #expect(tungsten.outputContrast == 0.85)
        }

        let historical = try #require(app.first { $0.stockId == "kodak5219" })
        var historicalJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(historical)) as? [String: Any])
        historicalJSON["outputContrast"] = 0.6
        let decodedHistorical = try JSONDecoder().decode(FilmStockConfig.self,
            from: JSONSerialization.data(withJSONObject: historicalJSON))
        #expect(decodedHistorical.outputContrast == 0.6)

        let constructorDefault = FilmStockConfig(stockId: "test", displayName: "Test", category: .video,
            lutName: "test.cube", halationStrength: 0, glowStrength: 0, grainSize: 1, defaultISO: 100)
        #expect(constructorDefault.outputContrast == 1.0)
    }

    @Test func colorTemperatureDecodesPerStock() throws {
        // White balance is fixed per stock: daylight 5600K, tungsten 3200K.
        let app = try stocks("App/Resources/stocks.json")
        func temp(_ id: String) throws -> Float {
            try #require(app.first { $0.stockId == id }).colorTemperature
        }
        #expect(try temp("kodak5219") == 3200)
        #expect(try temp("kodak5207") == 5600)
        // Tungsten stocks must NOT fall back to the daylight default (5600),
        // which would be the silent-failure mode of a `let`-declared property.
        #expect(try temp("kodak5219") != 5600)
    }

    @Test func recipeRoundTripAndRevisionEvidence() throws {
        var config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak5219" })
        let first = RenderDiagnosticsManifest.RecipeSnapshot(config: config, averageBitRate: RenderEncodingContract.averageBitRate, codec: RenderEncodingContract.codec)
        config.recipe?.version = "5219-current-v10-test"
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
        // Apple Log is documented as BT.2020 primaries, so the shipped 5219
        // recipes declare the input gamut. The contract is still user-declared.
        #expect(decoded.effectiveRecipe.input.gamut == "Rec.2020")
        #expect(decoded.effectiveRecipe.input.transfer == "Apple Log 2")
        #expect(decoded.effectiveRecipe.input.provenance == "user-declared")
        #expect(!decoded.colorContractVerified)
    }

    @Test func halationRecipeNamesThePreLUTLinearAlgorithm() throws {
        let catalogue = try stocks("App/Resources/stocks.json")
        #expect(catalogue.allSatisfy {
            $0.effectiveRecipe.halationAlgorithm == "scene-linear-pre-lut-layer-diffusion-v3"
        })
    }

    @Test func historicalHalationMetadataDecodesButCannotExecuteAsTheNewAlgorithm() throws {
        var historical = try #require(stocks("App/Resources/stocks.json").first)
        historical.recipe?.halationAlgorithm = "input-luma-spatial-highlight-addition-v2"
        let decoded = try JSONDecoder().decode(FilmStockConfig.self, from: JSONEncoder().encode(historical))
        #expect(decoded.effectiveRecipe.halationAlgorithm == "input-luma-spatial-highlight-addition-v2")
        #expect(throws: RenderContractError.self) { try decoded.validate() }
    }

    @Test func historicalLUTAlgorithmMetadataDecodesButCannotExecute() throws {
        let current = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak5219" })
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var recipe = try #require(object["recipe"] as? [String: Any])
        recipe["lutAlgorithm"] = "resolve-rgb-red-fastest-linear-clamp-v1"
        object["recipe"] = recipe

        let historical = try JSONDecoder().decode(FilmStockConfig.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(historical.effectiveRecipe.lutAlgorithm == "resolve-rgb-red-fastest-linear-clamp-v1")
        #expect(throws: RenderContractError.self) { try historical.validate() }
    }

    @Test func historicalGrainAlgorithmMetadataDecodesButCannotExecute() throws {
        let current = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak5219" })
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var recipe = try #require(object["recipe"] as? [String: Any])
        recipe["grainAlgorithm"] = "hashed-128-volume-iso-subtractive-dither-v1"
        object["recipe"] = recipe

        let historical = try JSONDecoder().decode(FilmStockConfig.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(historical.effectiveRecipe.grainAlgorithm == "hashed-128-volume-iso-subtractive-dither-v1")
        #expect(throws: RenderContractError.self) { try historical.validate() }
    }

    @Test func grainRecipeArchivesPreserveVersionedEdgeBoostDefaults() throws {
        let current = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak5219" })
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var recipe = try #require(object["recipe"] as? [String: Any])

        recipe.removeValue(forKey: "edgeBoostMultiplier")
        object["recipe"] = recipe
        let newRecipeWithoutScalar = try JSONDecoder().decode(FilmStockConfig.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(newRecipeWithoutScalar.effectiveRecipe.edgeBoostMultiplier == 3)
        try newRecipeWithoutScalar.validate()

        recipe["grainAlgorithm"] = RenderRecipe.legacyGrainAlgorithm
        recipe["version"] = "5219-current-v5"
        object["recipe"] = recipe
        let legacyRecipe = try JSONDecoder().decode(FilmStockConfig.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(legacyRecipe.effectiveRecipe.edgeBoostMultiplier == 0)
        try legacyRecipe.validate()

        recipe["edgeBoostMultiplier"] = 3
        object["recipe"] = recipe
        let invalidLegacyRecipe = try JSONDecoder().decode(FilmStockConfig.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: RenderContractError.self) { try invalidLegacyRecipe.validate() }
    }

    @Test func invalidParametersIdentifyTheStock() throws {
        let config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak5219" })
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
        for multiplier: Float in [-1, 4] {
            var badMultiplier = config
            badMultiplier.recipe?.edgeBoostMultiplier = multiplier
            #expect(throws: RenderContractError.self) { try badMultiplier.validate() }
        }
        for field in ["halationStrength", "glowStrength", "grainSize", "halationRadiusFraction"] {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
            object[field] = -1
            let bad = try JSONDecoder().decode(FilmStockConfig.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: RenderContractError.self) { try bad.validate() }
        }
    }

    @Test func halationGeometryDecodesPerStock() throws {
        // Geometry stays authored per stock, but both currently use the user's
        // shared 0.001 spread target. Channel weights remain stock-specific.
        let app = try stocks("App/Resources/stocks.json")
        func radius(_ id: String) throws -> Float {
            try #require(app.first { $0.stockId == id }).halationRadiusFraction
        }
        func tint(_ id: String) throws -> SIMD3<Float> {
            try #require(app.first { $0.stockId == id }).halationTint
        }
        #expect(try radius("kodak5207") == 0.001)
        #expect(try radius("kodak5219") == 0.001)

        // Published red-dominant range, full-scale red.
        #expect(try tint("kodak5219") == SIMD3(1.0, 0.32, 0.10))
        #expect(try tint("kodak5207") == SIMD3(1.0, 0.28, 0.10))
        #expect(app.allSatisfy { $0.halationTint.x == 1.0 })
        #expect(try tint("kodak5207") != tint("kodak5219"))
    }

    @Test func halationGainValidationAllowsTheTuningRangeAndRejectsInvalidValues() throws {
        func config(_ gain: Float) -> FilmStockConfig {
            FilmStockConfig(stockId: "gain-test", displayName: "Gain test", category: .video,
                lutName: "test.cube", halationStrength: gain, glowStrength: 0, grainSize: 1, defaultISO: 100)
        }
        for gain: Float in [0, 5, 8] { try config(gain).validate() }
        for gain: Float in [-1, .nan, .infinity, 8.01] {
            #expect(throws: RenderContractError.self) { try config(gain).validate() }
        }
    }

    @Test func halationGeometryValidationBounds() throws {
        let config = try #require(stocks("App/Resources/stocks.json").first { $0.stockId == "kodak5219" })

        var dimRed = config
        dimRed.halationTint = SIMD3(0.9, 0.30, 0.10)
        #expect(throws: RenderContractError.self) { try dimRed.validate() }

        var outOfRange = config
        outOfRange.halationTint = SIMD3(1.0, 1.5, 0.10)
        #expect(throws: RenderContractError.self) { try outOfRange.validate() }

        for radius: Float in [0, -1, 0.6] {
            var bad = config
            bad.halationRadiusFraction = radius
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
