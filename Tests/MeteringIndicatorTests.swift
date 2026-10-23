import CoreGraphics
import Foundation
import SwiftUI
import Testing

struct MeteringIndicatorTests {
    @MainActor @Test func visualIndicatorHasCircularBoundsInAutomaticAndManualModes() throws {
        for manual in [false, true] {
            let renderer = ImageRenderer(content: MeteringBoxView(point: CGPoint(x: 0.5, y: 0.5),
                                                                 isManual: manual)
                .frame(width: 200, height: 200))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let points = try visiblePoints(image)
            let minX = try #require(points.map(\.x).min())
            let maxX = try #require(points.map(\.x).max())
            let minY = try #require(points.map(\.y).min())
            let maxY = try #require(points.map(\.y).max())
            #expect(points.count > 60)
            #expect(abs((maxX - minX) - (maxY - minY)) <= 2,
                    "the metering cue must have equal circular width and height")
            #expect(abs((maxX + minX) / 2 - 100) <= 2)
            #expect(abs((maxY + minY) / 2 - 100) <= 2)
        }
    }

    @MainActor @Test func hiddenIndicatorRendersNoVisibleCue() throws {
        for manual in [false, true] {
            let indicator = MeteringBoxView(point: CGPoint(x: 0.5, y: 0.5),
                                             isManual: manual, isVisible: false)
            #expect(!indicator.isVisible)
            let renderer = ImageRenderer(content: indicator
                .frame(width: 200, height: 200).background(Color.black))
            let image = try #require(renderer.cgImage)
            let visible = try visiblePoints(image)
            #expect(visible.isEmpty, "manual=\(manual), visible pixels=\(visible.count)")
        }
    }

    @MainActor @Test func visibilityPreferenceDefaultsOnAndSurvivesReconstruction() throws {
        let suite = "MeteringIndicatorTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let setting = AppStorage(wrappedValue: MeteringIndicatorPreferences.defaultShowsIndicator,
                                 MeteringIndicatorPreferences.showsIndicatorKey, store: store)
        #expect(setting.wrappedValue)
        setting.wrappedValue = false
        let reopened = AppStorage(wrappedValue: MeteringIndicatorPreferences.defaultShowsIndicator,
                                  MeteringIndicatorPreferences.showsIndicatorKey, store: store)
        #expect(!reopened.wrappedValue)
        reopened.wrappedValue = true
        #expect(store.bool(forKey: MeteringIndicatorPreferences.showsIndicatorKey))
    }

    @Test func settingsPreferenceAffectsOnlyTheVisualOverlay() throws {
        let camera = try source("App/Modules/CameraCapture/CameraView.swift")
        let settings = try source("App/Modules/Purchase/PurchaseView.swift")
        #expect(settings.contains("title: \"Metering Indicator\""))
        #expect(settings.contains("@AppStorage(MeteringIndicatorPreferences.showsIndicatorKey)"))
        #expect(camera.contains("@AppStorage(MeteringIndicatorPreferences.showsIndicatorKey)"))
        let handler = try #require(camera.range(of: ".onTapGesture { location in"))
        let nextModifier = try #require(camera.range(of: ".onAppear", range: handler.upperBound..<camera.endIndex))
        let tap = String(camera[handler.lowerBound..<nextModifier.lowerBound])
        #expect(tap.contains("viewModel.handleFocusTap(at: location, in: layer)"))
        #expect(tap.contains("viewModel.setMeteringPoint("))
        #expect(!tap.contains("showsMeteringIndicator"),
                "hiding the cue must not gate tap-to-focus or exposure metering")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.url(for: path), encoding: .utf8)
    }

    private func visiblePoints(_ image: CGImage) throws -> [CGPoint] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width,
                                                height: image.height, bitsPerComponent: 8,
                                                bytesPerRow: image.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).compactMap { index in
            guard bytes[index + 3] > 40,
                  Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]) > 100 else { return nil }
            return CGPoint(x: (index / 4) % image.width, y: (index / 4) / image.width)
        }
    }
}
