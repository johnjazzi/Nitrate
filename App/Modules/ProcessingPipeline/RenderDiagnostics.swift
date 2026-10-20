import AVFoundation
import CryptoKit
import Foundation
import ImageIO
@preconcurrency import Metal
import UniformTypeIdentifiers

/// Evidence written by the opt-in CLI tracer. The schema is deliberately independent of UI.
struct RenderDiagnosticsManifest: Codable {
    struct Environment: Codable {
        let operatingSystem: String
        let target: String
        let metalDevice: String
        let metalRegistryID: UInt64
        let maxThreadsPerThreadgroup: [Int]
    }

    struct Media: Codable {
        let url: String
        let fileSize: Int64?
        let durationSeconds: Double?
        let width: Int?
        let height: Int?
        let nominalFrameRate: Float?
        let codec: String?
        let preferredTransform: [Double]?
        var colorProperties: [String: String]? = nil
    }

    struct Resource: Codable {
        let kind: String
        let path: String
        let sha256: String?
    }

    struct Frame: Codable {
        let role: String
        let requestedSeconds: Double
        let actualSeconds: Double?
        let file: String?
        let error: String?
    }

    struct Counters: Codable, Sendable {
        var decoded = 0
        var processed = 0
        var appended = 0
        var failed = 0
    }

    struct DecodedBufferEvidence: Codable, Equatable, Sendable {
        struct RGBPoint: Codable, Equatable, Sendable {
            let x: Int
            let y: Int
            let red: String
            let green: String
            let blue: String
        }

        let pixelFormat: String
        let width: Int
        let height: Int
        let colorAttachments: [String: String]
        let samplePoints: [RGBPoint]
    }

    struct RecipeSnapshot: Codable {
        let config: FilmStockConfig
        let averageBitRate: Int
        let codec: String
        let effectiveRecipe: RenderRecipe
        let colorContractVerified: Bool
        let sourceColorProvenance: RenderInputColorProvenance?

        init(config: FilmStockConfig, averageBitRate: Int, codec: String,
             sourceColorProvenance: RenderInputColorProvenance? = nil) {
            self.config = config
            self.averageBitRate = averageBitRate
            self.codec = codec
            self.effectiveRecipe = config.effectiveRecipe
            self.colorContractVerified = config.effectiveRecipe.colorContractVerified
            self.sourceColorProvenance = sourceColorProvenance
        }
    }

    var recipe: RecipeSnapshot? = nil
    var runID: UUID
    var startedAt: Date
    var finishedAt: Date?
    var stockID: String
    var iso: Float
    var environment: Environment
    var input: Media?
    var output: Media?
    var resources: [Resource]
    var counters = Counters()
    var firstDecodedBuffer: DecodedBufferEvidence?
    var timings: [String: Double] = [:]
    var sourceFrames: [Frame] = []
    var outputFrames: [Frame] = []
    var failureStage: String?
    var error: String?
    var succeeded = false
}

struct RenderDiagnosticResult {
    let outputURL: URL?
    let bundleURL: URL
    let manifest: RenderDiagnosticsManifest
}

enum RenderDiagnosticError: LocalizedError {
    case invalidBundleDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .invalidBundleDirectory(let url):
            return "Cannot create diagnostic bundle at \(url.path)."
        }
    }
}

enum RenderDiagnostics {
    static func writeInitialFailure(
        bundleDirectory: URL,
        inputURL: URL,
        stockID: String,
        iso: Float,
        stage: String,
        error: Error
    ) async -> URL? {
        let bundleURL = bundleDirectory.appendingPathComponent("render-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            let environment: RenderDiagnosticsManifest.Environment
            if let device = MTLCreateSystemDefaultDevice() {
                environment = makeEnvironment(device: device)
            } else {
                environment = .init(
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    target: Bundle.main.bundleIdentifier ?? CommandLine.arguments.first ?? "unknown",
                    metalDevice: "unavailable",
                    metalRegistryID: 0,
                    maxThreadsPerThreadgroup: [0, 0, 0]
                )
            }
            var manifest = RenderDiagnosticsManifest(
                runID: UUID(),
                startedAt: Date(),
                finishedAt: Date(),
                stockID: stockID,
                iso: iso,
                environment: environment,
                input: await inspectMedia(url: inputURL),
                output: nil,
                resources: []
            )
            manifest.failureStage = stage
            manifest.error = error.localizedDescription
            manifest.counters.failed = 1
            try writeManifest(manifest, to: bundleURL)
            return bundleURL
        } catch {
            return nil
        }
    }

    static func makeEnvironment(device: MTLDevice) -> RenderDiagnosticsManifest.Environment {
        RenderDiagnosticsManifest.Environment(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            target: Bundle.main.bundleIdentifier ?? CommandLine.arguments.first ?? "unknown",
            metalDevice: device.name,
            metalRegistryID: device.registryID,
            maxThreadsPerThreadgroup: [
                device.maxThreadsPerThreadgroup.width,
                device.maxThreadsPerThreadgroup.height,
                device.maxThreadsPerThreadgroup.depth
            ]
        )
    }

    static func resource(kind: String, url: URL) -> RenderDiagnosticsManifest.Resource {
        let hash = (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        return .init(kind: kind, path: url.path, sha256: hash)
    }

    static func inspectMedia(url: URL) async -> RenderDiagnosticsManifest.Media {
        let asset = AVURLAsset(url: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let videoTrack = tracks.first else {
            return .init(url: url.path, fileSize: size, durationSeconds: nil, width: nil, height: nil, nominalFrameRate: nil, codec: nil, preferredTransform: nil)
        }
        let naturalSize = try? await videoTrack.load(.naturalSize)
        let duration = try? await asset.load(.duration)
        let rate = try? await videoTrack.load(.nominalFrameRate)
        let transform = try? await videoTrack.load(.preferredTransform)
        let codec = try? await videoTrack.load(.formatDescriptions).first.map { description in
            CMFormatDescriptionGetMediaSubType(description).fourCharCodeString
        }
        let descriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
        var colorProperties: [String: String] = [:]
        for (index, description) in descriptions.enumerated() {
            guard let rawExtensions = CMFormatDescriptionGetExtensions(description) else { continue }
            let extensions = rawExtensions as NSDictionary
            var keys: [CFString] = [kCMFormatDescriptionExtension_ColorPrimaries,
                                    kCMFormatDescriptionExtension_TransferFunction,
                                    kCMFormatDescriptionExtension_YCbCrMatrix,
                                    kCMFormatDescriptionExtension_FullRangeVideo,
                                    kCMFormatDescriptionExtension_BitsPerComponent]
            if #available(iOS 17.2, macOS 14.2, tvOS 17.2, *) {
                keys.append(kCMFormatDescriptionExtension_LogTransferFunction)
            }
            for key in keys {
                if let value = extensions[key] {
                    colorProperties["format-\(index).\(key as String)"] = String(describing: value)
                }
            }
        }
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata where (item.key as? String) == "com.filmemulation.capture-color-space" {
                if let value = try? await item.load(.stringValue) { colorProperties["capture-color-space"] = value }
            }
        }
        return .init(
            url: url.path,
            fileSize: size,
            durationSeconds: duration?.seconds,
            width: naturalSize.map { Int($0.width) },
            height: naturalSize.map { Int($0.height) },
            nominalFrameRate: rate,
            codec: codec,
            preferredTransform: transform.map { [$0.a, $0.b, $0.c, $0.d, $0.tx, $0.ty] },
            colorProperties: colorProperties
        )
    }

    static func extractFrames(from url: URL, directory: URL) async -> [RenderDiagnosticsManifest.Frame] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            return ["start", "middle", "end"].enumerated().map { index, role in
                .init(role: role, requestedSeconds: Double(index), actualSeconds: nil, file: nil, error: "Unable to load media duration.")
            }
        }
        let requested = [0.0, duration.seconds / 2, max(0, duration.seconds - 0.1)]
        let roles = ["start", "middle", "end"]
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [RenderDiagnosticsManifest.Frame] = []
        for (role, seconds) in zip(roles, requested) {
            let request = CMTime(seconds: seconds, preferredTimescale: 600)
            do {
                // `image(at:)` replaces the synchronous `copyCGImage(at:actualTime:)`
                // and reports the actual frame time it produced.
                let generated = try await generator.image(at: request)
                let file = "\(role).png"
                let destination = directory.appendingPathComponent(file)
                guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw NSError(domain: "RenderDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create PNG destination."])
                }
                CGImageDestinationAddImage(writer, generated.image, nil)
                guard CGImageDestinationFinalize(writer) else {
                    throw NSError(domain: "RenderDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to write PNG."])
                }
                frames.append(.init(role: role, requestedSeconds: seconds,
                                    actualSeconds: generated.actualTime.seconds, file: file, error: nil))
            } catch {
                frames.append(.init(role: role, requestedSeconds: seconds, actualSeconds: nil, file: nil, error: error.localizedDescription))
            }
        }
        return frames
    }

    static func writeManifest(_ manifest: RenderDiagnosticsManifest, to bundleURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let target = bundleURL.appendingPathComponent("manifest.json")
        let temporary = bundleURL.appendingPathComponent("manifest.json.tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }
}

/// Portable export evidence; selected render ISO is not a measurement of capture ISO.
enum RenderMovieMetadata {
    static func make(config: FilmStockConfig, bitrate: Int = RenderEncodingContract.averageBitRate,
                     sourceColorProvenance: RenderInputColorProvenance? = nil,
                     orientation: RenderDeliveryOrientation? = nil,
                     capturePolicy: RenderCapturePolicy? = nil) throws -> [AVMetadataItem] {
        try config.validate()
        let snapshot = RenderDiagnosticsManifest.RecipeSnapshot(config: config,
            averageBitRate: bitrate, codec: RenderEncodingContract.codec,
            sourceColorProvenance: sourceColorProvenance)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        let values: [String: String] = [
            "film-stock": config.stockId, "stock-name": config.displayName, "lut": config.lutName,
            "light-type": config.lightType,
            "iso": String(Int(config.defaultISO)), "iso-role": "selected-render-exposure-index",
            "halation-level": String(config.halationStrength), "glow-level": String(config.glowStrength),
            "halation-radius-fraction": String(config.halationRadiusFraction),
            "halation-tint": "\(config.halationTint.x),\(config.halationTint.y),\(config.halationTint.z)",
            "grain-size": String(config.grainSize), "recipe-version": config.effectiveRecipe.version,
            "print-gauge": config.effectivePrintGauge.rawValue,
            "grain-size-effective": String(GrainModel.effectiveSize(stockGrainSize: config.grainSize,
                                                                   gauge: config.effectivePrintGauge)),
            "grain-gauge-amplitude": String(config.effectivePrintGauge.amplitudeMultiplier),
            "grain-algorithm": config.effectiveRecipe.grainAlgorithm,
            "grain-edge-boost-multiplier": String(config.effectiveRecipe.edgeBoostMultiplier),
            "shutter-speed": "1/48", "shutter-angle": "180",
            "encoding-codec": RenderEncodingContract.codec,
            "encoding-bitrate-target": String(bitrate),
            "color-contract-verified": String(config.effectiveRecipe.colorContractVerified),
            "render-settings-schema": "1", "render-settings": json
        ]
        var metadataValues = values
        if let sourceColorProvenance {
            let sourceData = try JSONEncoder().encode(sourceColorProvenance)
            metadataValues["source-color-validation"] = sourceColorProvenance.validationStatus
            metadataValues["source-color-provenance"] = String(decoding: sourceData, as: UTF8.self)
            metadataValues["capture-color-space"] = sourceColorProvenance.captureColorSpace ?? "unknown-or-not-recorded"
            metadataValues["source-color-test-bypass"] = String(sourceColorProvenance.syntheticTestBypass)
        }
        var items: [AVMutableMetadataItem] = metadataValues.sorted { $0.key < $1.key }.map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.filmemulation.\(key)" as NSString
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        // Consumer-visible fields, shown by Photos, Finder Get Info and QuickTime
        // Movie Inspector (⌘I). Kept to the single short tag on purpose: the
        // detailed recipe lives in the render-settings JSON instead of a caption
        // that exposes every effect value to the photo library.
        let caption = RenderConsumerMetadata.caption(stockName: config.displayName,
                                                     gauge: config.effectivePrintGauge.rawValue)
        items.append(Self.commonItem(key: AVMetadataKey.commonKeyTitle.rawValue, value: caption))
        items.append(Self.commonItem(key: AVMetadataKey.commonKeyDescription.rawValue, value: caption))
        items.append(Self.keywordsItem(RenderConsumerMetadata.keywordsValue(orientation: orientation)))
        return items
    }

    private static func commonItem(key: String, value: String) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .common
        item.key = key as NSString
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// Standard QuickTime keyword list, read by consumer apps and photo tools.
    private static func keywordsItem(_ value: String) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyKeywords.rawValue as NSString
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }
}

extension FourCharCode {
    var fourCharCodeString: String {
        let bytes: [UInt8] = [UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "unknown"
    }
}
