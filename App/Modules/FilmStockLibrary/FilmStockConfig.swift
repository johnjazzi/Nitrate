import Foundation

/// AD-10: Value-type contract for film stock configuration.
/// Never constructed directly — always via FilmStockLibrary.
struct FilmStockConfig: Codable, Equatable, Sendable {
    let stockId: String
    let displayName: String
    let category: StockCategory
    let lutName: String
    let halationStrength: Float
    let glowStrength: Float
    let defaultISO: Float

    enum StockCategory: String, Codable, Equatable {
        case video
        case photo
    }
}