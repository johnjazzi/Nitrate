import Foundation
import Testing

struct PhotoCubeValidationTests {
    private func cube(_ filename: String) throws -> ([SIMD3<Double>], Int) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/LUTs/\(filename)")
        let text = try String(contentsOf: url, encoding: .utf8)
        var size: Int?
        var values: [SIMD3<Double>] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let row = line.split(whereSeparator: \.isWhitespace)
            guard let first = row.first else { continue }
            if first == "LUT_3D_SIZE", row.count == 2 { size = Int(row[1]); continue }
            if first.hasPrefix("#") || ["TITLE", "DOMAIN_MIN", "DOMAIN_MAX"].contains(String(first)) { continue }
            if row.count == 3, let r = Double(row[0]), let g = Double(row[1]), let b = Double(row[2]) {
                values.append(SIMD3(r, g, b))
            }
        }
        guard let size else { throw NSError(domain: "PhotoCube", code: 1) }
        return (values, size)
    }

    @Test func actual5207And5219CubesMatchDeclaredGridAndNeutralCheckpoints() throws {
        for (name, expected) in [
            ("5207 - Apple Log 2.cube", SIMD3(0.50888984, 0.50604270, 0.50375518)),
            ("5219 - Apple Log 2.cube", SIMD3(0.50922307, 0.50623148, 0.50400868))
        ] {
            let (data, size) = try cube(name)
            #expect(size == 33)
            #expect(data.count == 35_937)
            let encoded = try RAWToLog2Stage.apply(SIMD3(repeating: 0.18)).appleLog2
            let p = encoded * Double(size - 1)
            let lo = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
            let f = p - SIMD3<Double>(Double(lo.x), Double(lo.y), Double(lo.z))
            func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> { data[r + g * size + b * size * size] }
            var result = SIMD3<Double>.zero
            for bz in 0...1 { for gy in 0...1 { for rx in 0...1 {
                let w = (rx == 0 ? 1-f.x : f.x) * (gy == 0 ? 1-f.y : f.y) * (bz == 0 ? 1-f.z : f.z)
                result += at(lo.x+rx, lo.y+gy, lo.z+bz) * w
            }}}
            #expect(abs(result.x - expected.x) < 1e-6, "\(name)")
            #expect(abs(result.y - expected.y) < 1e-6, "\(name)")
            #expect(abs(result.z - expected.z) < 1e-6, "\(name)")
        }
    }
}
