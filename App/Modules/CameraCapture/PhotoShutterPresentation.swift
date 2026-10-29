import Foundation

/// Pure presentation data for the Photo shutter ruler.
enum PhotoShutterPresentation {
    static func detents(in supportedRange: ClosedRange<Double>) -> [Double] {
        guard supportedRange.lowerBound.isFinite, supportedRange.upperBound.isFinite,
              supportedRange.lowerBound > 0 else { return [] }
        let standards: [Double] = [1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000,
                                   1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60,
                                   1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4,
                                   1.0 / 2, 1, 2, 4, 8, 15, 30]
        let values = standards.filter { supportedRange.contains($0) }
        return Array(Set([supportedRange.lowerBound] + values + [supportedRange.upperBound])).sorted()
    }

    static func label(for durationSeconds: Double) -> String {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return "—" }
        if durationSeconds >= 1 {
            return String(format: "%.4g″", durationSeconds)
        }
        let reciprocal = (1.0 / durationSeconds).rounded()
        guard reciprocal.isFinite, reciprocal < Double(Int.max) else { return "—" }
        return "1/\(Int(reciprocal))"
    }
}
