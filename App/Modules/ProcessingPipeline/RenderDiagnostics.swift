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

    struct Counters: Codable {
        var decoded = 0
        var processed = 0
        var appended = 0
        var failed = 0
    }

    struct RecipeSnapshot: Codable {
        let config: FilmStockConfig
        let averageBitRate: Int
        let codec: String
        let effectiveRecipe: RenderRecipe
        let colorContractVerified: Bool

        init(config: FilmStockConfig, averageBitRate: Int, codec: String) {
            self.config = config
            self.averageBitRate = averageBitRate
            self.codec = codec
            self.effectiveRecipe = config.effectiveRecipe
            self.colorContractVerified = config.effectiveRecipe.colorContractVerified
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
        let asset = AVAsset(url: url)
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
        let descriptions = try? await videoTrack.load(.formatDescriptions)
        var colorProperties: [String: String] = [:]
        if let description = descriptions?.first,
           let rawExtensions = CMFormatDescriptionGetExtensions(description) {
            let extensions = rawExtensions as NSDictionary
            for key in [kCMFormatDescriptionExtension_ColorPrimaries,
                        kCMFormatDescriptionExtension_TransferFunction,
                        kCMFormatDescriptionExtension_YCbCrMatrix,
                        kCMFormatDescriptionExtension_FullRangeVideo] {
                if let value = extensions[key] { colorProperties[key as String] = String(describing: value) }
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
        let asset = AVAsset(url: url)
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
        return zip(roles, requested).map { role, seconds in
            let request = CMTime(seconds: seconds, preferredTimescale: 600)
            do {
                var actual = CMTime.zero
                let image = try generator.copyCGImage(at: request, actualTime: &actual)
                let file = "\(role).png"
                let destination = directory.appendingPathComponent(file)
                guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw NSError(domain: "RenderDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create PNG destination."])
                }
                CGImageDestinationAddImage(writer, image, nil)
                guard CGImageDestinationFinalize(writer) else {
                    throw NSError(domain: "RenderDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to write PNG."])
                }
                return .init(role: role, requestedSeconds: seconds, actualSeconds: actual.seconds, file: file, error: nil)
            } catch {
                return .init(role: role, requestedSeconds: seconds, actualSeconds: nil, file: nil, error: error.localizedDescription)
            }
        }
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
    static func make(config: FilmStockConfig, bitrate: Int = RenderEncodingContract.averageBitRate) throws -> [AVMetadataItem] {
        try config.validate()
        let snapshot = RenderDiagnosticsManifest.RecipeSnapshot(config: config,
            averageBitRate: bitrate, codec: RenderEncodingContract.codec)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        let values: [String: String] = [
            "film-stock": config.stockId, "stock-name": config.displayName, "lut": config.lutName,
            "iso": String(Int(config.defaultISO)), "iso-role": "selected-render-exposure-index",
            "halation-level": String(config.halationStrength), "glow-level": String(config.glowStrength),
            "grain-size": String(config.grainSize), "recipe-version": config.effectiveRecipe.version,
            "encoding-codec": RenderEncodingContract.codec,
            "encoding-bitrate-target": String(bitrate),
            "color-contract-verified": String(config.effectiveRecipe.colorContractVerified),
            "render-settings-schema": "1", "render-settings": json
        ]
        var items: [AVMutableMetadataItem] = values.sorted { $0.key < $1.key }.map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.filmemulation.\(key)" as NSString
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        // Human-readable fields shown by Finder Get Info and QuickTime Movie Inspector (⌘I);
        // the custom com.filmemulation.* keys above are invisible in consumer apps.
        items.append(Self.commonItem(key: AVMetadataKey.commonKeyTitle.rawValue, value: config.displayName))
        items.append(Self.commonItem(key: AVMetadataKey.commonKeyDescription.rawValue, value: Self.humanReadableSummary(config, bitrate: bitrate)))
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

    private static func humanReadableSummary(_ config: FilmStockConfig, bitrate: Int) -> String {
        "ISO \(Int(config.defaultISO)) · halation \(config.halationStrength) · glow \(config.glowStrength) · "
            + "grain \(config.grainSize) · \(RenderEncodingContract.codec) @ \(bitrate / 1_000_000) Mbps"
    }
}

private extension FourCharCode {
    var fourCharCodeString: String {
        let bytes: [UInt8] = [UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "unknown"
    }
}
