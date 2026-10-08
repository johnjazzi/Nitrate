import Foundation
import SwiftUI

/// AD-10: Value-type contract for film stock configuration.
/// Never constructed directly — always via FilmStockLibrary.
struct FilmStockConfig: Codable, Equatable, Sendable {
    let stockId: String
    let displayName: String
    let category: StockCategory
    let lutName: String
    let halationStrength: Float
    let glowStrength: Float
    let grainSize: Float
    let defaultISO: Float

    /// Primary tint hex for duotone display (e.g. "#E8C46C"). Optional; defaults to grey.
    var primaryTint: String?
    /// Secondary tint hex for duotone display. Optional; defaults to a darker shade.
    var secondaryTint: String?

    /// Daylight (D) or Tungsten (T) based on display name.
    var lightType: String {
        let uppercased = displayName.uppercased()
        if uppercased.contains("T") && !uppercased.contains("DI") { return "T" }
        return "D"
    }

    var primaryColor: Color {
        if let hex = primaryTint { return Color(hex: hex) }
        return .gray
    }

    var secondaryColor: Color {
        if let hex = secondaryTint { return Color(hex: hex) }
        return primaryColor.opacity(0.5)
    }

    enum StockCategory: String, Codable, Equatable {
        case video
        case photo
    }
}

// MARK: - Color Hex Helper

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 128, 128, 128)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}