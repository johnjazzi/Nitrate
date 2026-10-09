import AVFoundation
import Foundation

@main struct RenderCLI {
    struct CLIStocksContainer: Codable { let stocks: [FilmStockConfig] }

    static func loadConfig(for stockId: String, iso: Float) throws -> FilmStockConfig {
        guard let url = Bundle.main.url(forResource: "stocks", withExtension: "json") else {
            throw NSError(domain: "RenderCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing stocks.json"])
        }
        let container = try JSONDecoder().decode(CLIStocksContainer.self, from: Data(contentsOf: url))
        guard let template = container.stocks.first(where: { $0.stockId == stockId }) else {
            throw NSError(domain: "RenderCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stock not found: \(stockId)"])
        }
        let config = template.overridingISO(iso)
        try config.validate()
        return config
    }

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            print("Usage: RenderCLI <input.mov> <stockId> [iso] [--bitrate <bps>] [--diagnostics <bundle-directory>]")
            exit(1)
        }
        let inputPath = arguments[0]
        let stockId = arguments[1]
        var iso: Float = 400
        var bitrate: Int = RenderEncodingContract.averageBitRate
        var diagnosticsDirectory: URL?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--diagnostics":
                guard index + 1 < arguments.count else {
                    print("--diagnostics requires a bundle directory.")
                    exit(1)
                }
                diagnosticsDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                index += 2
            case "--bitrate":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                    print("--bitrate requires an integer bits-per-second value.")
                    exit(1)
                }
                bitrate = value
                index += 2
            default:
                guard let value = Float(arguments[index]) else {
                    print("Unknown argument: \(arguments[index])")
                    exit(1)
                }
                iso = value
                index += 1
            }
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: inputPath) else {
            if let diagnosticsDirectory {
                let error = NSError(domain: "RenderCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Input file not found: \(inputPath)"])
                if let bundle = await RenderDiagnostics.writeInitialFailure(
                    bundleDirectory: diagnosticsDirectory,
                    inputURL: inputURL,
                    stockID: stockId,
                    iso: iso,
                    stage: "input",
                    error: error
                ) {
                    print("Diagnostic bundle: \(bundle.path)")
                }
            }
            print("Input file not found: \(inputPath)")
            exit(1)
        }

        let config: FilmStockConfig
        do {
            config = try loadConfig(for: stockId, iso: iso)
        } catch {
            if let diagnosticsDirectory {
                if let bundle = await RenderDiagnostics.writeInitialFailure(
                    bundleDirectory: diagnosticsDirectory,
                    inputURL: inputURL,
                    stockID: stockId,
                    iso: iso,
                    stage: "configuration",
                    error: error
                ) {
                    print("Diagnostic bundle: \(bundle.path)")
                }
            }
            print("Configuration failed: \(error.localizedDescription)")
            exit(1)
        }

        print("Rendering \(inputPath) with \(stockId) at ISO \(Int(iso))...")
        var diagnosticRenderStarted = false
        do {
            let renderer = try PipelineRenderer()
            if let diagnosticsDirectory {
                diagnosticRenderStarted = true
                let result = try await renderer.render(
                    sourceURL: inputURL,
                    config: config,
                    bitrate: bitrate,
                    diagnosticsBundleDirectory: diagnosticsDirectory
                )
                print("Rendered to: \(result.outputURL?.path ?? "unavailable")")
                print("Diagnostic bundle: \(result.bundleURL.path)")
            } else {
                let outputURL = try await renderer.render(sourceURL: inputURL, config: config, bitrate: bitrate)
                print("Rendered to: \(outputURL.path)")
            }
        } catch {
            if let diagnosticsDirectory, !diagnosticRenderStarted {
                if let bundle = await RenderDiagnostics.writeInitialFailure(
                    bundleDirectory: diagnosticsDirectory,
                    inputURL: inputURL,
                    stockID: stockId,
                    iso: iso,
                    stage: "renderer-initialization",
                    error: error
                ) {
                    print("Diagnostic bundle: \(bundle.path)")
                }
            }
            print("Render failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
