import Foundation
import Testing

struct DevelopExposureMeterTests {
    @Test func grayAndStopLadderAreSceneLinearNotDisplayGamma() throws {
        for stops in -5...5 {
            let value = 0.18 * pow(2, Double(stops))
            let reading = try #require(DevelopExposureMeter.offsetEV(luminance: [Double](repeating: value, count: 35),
                                                                      width: 7, height: 5))
            #expect(abs(reading - Double(stops)) < 0.000001)
        }
        let logGray = PhotoColorMath.appleLog2Encode(0.18)
        #expect(abs(DevelopExposureMeter.appleLog2Luminance(SIMD3(repeating: logGray)) - 0.18) < 0.000001)
        #expect(abs(DevelopExposureMeter.linearSRGBLuminance(SIMD3(1, 0, 0)) - 0.2126) < 0.000001)
    }

    @Test func centralLightHasMoreWeightThanIdenticalEdgeLight() throws {
        var center = [Double](repeating: 0.02, count: 81)
        var edge = center
        center[40] = 1
        edge[0] = 1
        let centralReading = try #require(DevelopExposureMeter.offsetEV(luminance: center, width: 9, height: 9))
        let edgeReading = try #require(DevelopExposureMeter.offsetEV(luminance: edge, width: 9, height: 9))
        #expect(centralReading > edgeReading)
        // Reflection leaves a centered weight unchanged.
        let reflected = Array(center.reversed())
        #expect(DevelopExposureMeter.offsetEV(luminance: reflected, width: 9, height: 9) == centralReading)
    }

    @Test func unavailableSamplesNeverBecomeZeroEVOrPoisonFiniteSamples() throws {
        #expect(DevelopExposureMeter.offsetEV(luminance: [], width: 0, height: 0) == nil)
        #expect(DevelopExposureMeter.offsetEV(luminance: [0.18], width: 2, height: 1) == nil)
        #expect(DevelopExposureMeter.offsetEV(luminance: [0], width: 1, height: 1) == nil)
        #expect(DevelopExposureMeter.offsetEV(luminance: [.nan, .infinity, -1], width: 3, height: 1) == nil)
        let reading = try #require(DevelopExposureMeter.offsetEV(luminance: [.nan, 0.18, .infinity], width: 3, height: 1))
        #expect(abs(reading) < 0.000001)
        #expect(DevelopExposureMeter.linearSRGBLuminance(SIMD3(.nan, 1, 1)).isNaN)
        #expect(DevelopExposureMeter.appleLog2Luminance(SIMD3(.infinity, 0.5, 0.5)).isNaN)
    }

    @Test func hlgMeasurementUsesCameraSceneNormalizationNotDisplayOOTF() {
        // Production hlg-input.h defines 75% signal as diffuse white (1.0).
        let white = DevelopExposureMeter.hlgLuminance(y: 64 + 876 * 0.75, cb: 512, cr: 512)
        #expect(abs(white - 1) < 0.00001)
        #expect(DevelopExposureMeter.hlgLuminance(y: 64, cb: 512, cr: 512) == 0)
        #expect(DevelopExposureMeter.hlgLuminance(y: .nan, cb: 512, cr: 512).isNaN)
    }
}
