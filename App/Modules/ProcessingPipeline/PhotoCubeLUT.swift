import Foundation

/// Shared Resolve cube parser; direct RGB, red-fastest upload contract.
enum PhotoCubeLUT {
    static func parse(_ content: String) throws -> (Int, [Float]) {
        var size = 0
        var values: [Float] = []
        var headerParsed = false

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.uppercased().hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                guard parts.count >= 2, let parsedSize = Int(parts[1]) else {
                    throw RenderError.invalidLUTData
                }
                size = parsedSize
                headerParsed = true
                continue
            }

            if headerParsed, trimmed.uppercased() == "DOMAIN_MIN" || trimmed.uppercased() == "DOMAIN_MAX" {
                continue
            }

            if headerParsed {
                // Parse RGB triplet
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                let numericParts = parts.compactMap { Float($0) }
                if numericParts.count == 3 {
                    values.append(contentsOf: numericParts + [1.0]) // Add alpha = 1.0
                }
            }
        }

        guard size > 0, values.count == size * size * size * 4 else {
            throw RenderError.invalidLUTData
        }

        return (size, values)
    }

}
