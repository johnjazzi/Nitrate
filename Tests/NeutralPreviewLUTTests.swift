import CryptoKit
import Foundation
import Testing

/// Regression checks for the sourced neutral monitor transform, not display calibration.
struct NeutralPreviewLUTTests {
    @Test func assetMatchesReviewedSourceAndHasCompleteFiniteGrid() throws {
        let data = try Data(contentsOf: assetURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "831b0e32a18ceba3d93fdf0c2816c01163a67fadd48550a3276167b3b2b1e7f2")
        let cube = try loadCube()
        #expect(cube.size == 33)
        #expect(cube.values.count == 33 * 33 * 33)
        #expect(cube.values.allSatisfy { $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.00001 } })
    }

    @Test func neutralAxisIsAchromaticAndMonotonicWithSDRHighlightRollOff() throws {
        let cube = try loadCube()
        let axis = (0..<cube.size).map { cube.sample($0, $0, $0) }
        for rgb in axis {
            #expect((rgb.max() ?? 0) - (rgb.min() ?? 0) < 0.000002)
        }
        for index in 1..<axis.count {
            for channel in 0..<3 {
                #expect(axis[index][channel] >= axis[index - 1][channel] - 0.000001)
            }
        }
        // Actual OCIO source samples at normalized Log inputs 0, .25, .5, .75, 1.
        let expected: [(Int, Float)] = [(0, 0), (8, 0.080587), (16, 0.402230),
                                        (24, 0.796408), (32, 0.967356)]
        for (index, value) in expected {
            for channel in 0..<3 {
                #expect(abs(axis[index][channel] - value) < 0.00001)
            }
        }
        #expect(axis[32][0] - axis[28][0] < axis[20][0] - axis[16][0])
    }

    @Test func asymmetricSourceSamplesPinAppleWideGamutAndRedFastestOrdering() throws {
        let cube = try loadCube()
        // These fail for channel-swapped uploads, identity cubes, and Apple Log 1 input.
        let samples: [(Int, Int, Int, [Float])] = [
            (16, 8, 4, [0.406324685, 0.138296574, 0]),
            (4, 8, 16, [0, 0.092437297, 0.244335920])
        ]
        for (red, green, blue, expected) in samples {
            let actual = cube.sample(red, green, blue)
            for channel in 0..<3 {
                #expect(abs(actual[channel] - expected[channel]) < 0.00001)
            }
        }
    }

    private struct Cube {
        let size: Int
        let values: [[Float]]

        func sample(_ red: Int, _ green: Int, _ blue: Int) -> [Float] {
            values[red + green * size + blue * size * size]
        }
    }

    private enum AssetError: Error { case missingAsset, malformedCube }

    // The renderer's parser is private. This mirrors its RGB/red-fastest contract
    // without constructing a Metal renderer; no new production parsing API.
    private func loadCube() throws -> Cube {
        let text = try String(contentsOf: assetURL, encoding: .utf8)
        var size = 0
        var values: [[Float]] = []
        for line in text.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = words.first, !first.hasPrefix("#") else { continue }
            if first == "TITLE" { continue }
            if first == "LUT_3D_SIZE", words.count == 2, let parsed = Int(words[1]) {
                size = parsed
                continue
            }
            let rgb = words.compactMap { Float($0) }
            guard size > 0, words.count == 3, rgb.count == 3 else { throw AssetError.malformedCube }
            values.append(rgb)
        }
        guard size == 33, values.count == size * size * size else { throw AssetError.malformedCube }
        return Cube(size: size, values: values)
    }

    private var assetURL: URL {
        get throws {
            let source = TestRepository.root.appendingPathComponent("App/Resources/Preview/AppleLog2ToRec709.cube")
            if FileManager.default.fileExists(atPath: source.path) { return source }
            if let bundled = Bundle.main.url(forResource: "AppleLog2ToRec709", withExtension: "cube",
                                              subdirectory: "Preview") { return bundled }
            throw AssetError.missingAsset
        }
    }
}
