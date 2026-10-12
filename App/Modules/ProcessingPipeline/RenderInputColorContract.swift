import AVFoundation
import CoreVideo
import Foundation

/// Stream-level evidence for the input consumed by the Apple Log 2 LUT.
/// Ordinary transfer and primaries tags are retained as evidence but never
/// substitute for the distinct LogTransferFunction identifier.
struct RenderInputColorProvenance: Codable, Equatable, Sendable {
    struct FormatEvidence: Codable, Equatable, Sendable {
        let logTransferFunction: String?
        let colorPrimaries: String?
        let transferFunction: String?
        let yCbCrMatrix: String?
        let bitDepth: String?
        var fullRangeVideo: String? = nil
        var codec: String? = nil

        var summary: String {
            "log=\(logTransferFunction ?? "missing"), primaries=\(colorPrimaries ?? "missing"), "
                + "transfer=\(transferFunction ?? "missing"), matrix=\(yCbCrMatrix ?? "missing")"
        }
    }

    let expected: String
    let validationStatus: String
    let formatDescriptions: [FormatEvidence]
    let captureColorSpace: String?
    let syntheticTestBypass: Bool

    var sourceSummary: String { formatDescriptions.map(\.summary).joined(separator: "; ") }

    static func inspect(_ descriptions: [CMFormatDescription], captureColorSpace: String? = nil) throws -> Self {
        let evidence = descriptions.map(evidence(for:))
        try validate(evidence)
        return .init(expected: "Apple Log 2", validationStatus: "accepted-stream-tags",
                     formatDescriptions: evidence, captureColorSpace: captureColorSpace,
                     syntheticTestBypass: false)
    }

    static func syntheticTestBypass(_ descriptions: [CMFormatDescription], captureColorSpace: String? = nil) -> Self {
        .init(expected: "Apple Log 2", validationStatus: "explicit-synthetic-test-bypass",
              formatDescriptions: descriptions.map(evidence(for:)), captureColorSpace: captureColorSpace,
              syntheticTestBypass: true)
    }

    static func validate(_ evidence: [FormatEvidence]) throws {
        guard !evidence.isEmpty else {
            throw RenderInputColorContractError(expected: "Apple Log 2", observed: "no video format descriptions")
        }
        for item in evidence {
            guard isAppleLog2(item.logTransferFunction) else {
                throw RenderInputColorContractError(expected: "Apple Log 2", observed: item.summary)
            }
            guard item.colorPrimaries == nil,
                  item.transferFunction == nil,
                  item.yCbCrMatrix == (AVVideoYCbCrMatrix_ITU_R_2020 as String) else {
                throw RenderInputColorContractError(expected: "Apple Log 2", observed: "incompatible or undefined color tags: \(item.summary)")
            }
        }
    }

    private static func evidence(for description: CMFormatDescription) -> FormatEvidence {
        var values: [String: String] = [:]
        var logTransferFunction: String?
        if #available(iOS 17.2, macOS 14.2, tvOS 17.2, *) {
            if let raw = CMFormatDescriptionGetExtensions(description) as NSDictionary? {
                if let value = raw[kCMFormatDescriptionExtension_LogTransferFunction] {
                    logTransferFunction = String(describing: value)
                }
                for key in [kCMFormatDescriptionExtension_ColorPrimaries,
                            kCMFormatDescriptionExtension_TransferFunction,
                            kCMFormatDescriptionExtension_YCbCrMatrix,
                            kCMFormatDescriptionExtension_BitsPerComponent,
                            kCMFormatDescriptionExtension_FullRangeVideo] {
                    if let value = raw[key] { values[key as String] = String(describing: value) }
                }
            }
        } else if let raw = CMFormatDescriptionGetExtensions(description) as NSDictionary? {
            for key in [kCMFormatDescriptionExtension_ColorPrimaries,
                        kCMFormatDescriptionExtension_TransferFunction,
                        kCMFormatDescriptionExtension_YCbCrMatrix,
                        kCMFormatDescriptionExtension_BitsPerComponent,
                        kCMFormatDescriptionExtension_FullRangeVideo] {
                if let value = raw[key] { values[key as String] = String(describing: value) }
            }
        }
        return .init(
            logTransferFunction: logTransferFunction,
            colorPrimaries: values[kCMFormatDescriptionExtension_ColorPrimaries as String],
            transferFunction: values[kCMFormatDescriptionExtension_TransferFunction as String],
            yCbCrMatrix: values[kCMFormatDescriptionExtension_YCbCrMatrix as String],
            bitDepth: values[kCMFormatDescriptionExtension_BitsPerComponent as String],
            fullRangeVideo: values[kCMFormatDescriptionExtension_FullRangeVideo as String],
            codec: CMFormatDescriptionGetMediaSubType(description).fourCharCodeString
        )
    }

    private static func isAppleLog2(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            return identifier == (kCVImageBufferLogTransferFunction_AppleLog2 as String)
        }
        // Stable reverse-DNS identifier documented by VideoToolbox. Older
        // supported macOS versions can inspect LogTransferFunction but lack
        // the exported Apple Log 2 value symbol.
        return identifier == "com.apple.apple-wide-gamut.apple-log"
    }
}

struct RenderInputColorContractError: LocalizedError, Equatable {
    let expected: String
    let observed: String

    var errorDescription: String? {
        "input-color-contract: expected \(expected); observed \(observed)."
    }
}
