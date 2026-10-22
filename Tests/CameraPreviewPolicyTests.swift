import Foundation
import CoreGraphics
import Testing

struct CameraPreviewPolicyTests {
    @Test func previewRotationUsesThePlatformAnglePerCamera() {
        // The front camera's native buffer is portrait-sized, so its preview
        // angle is 0 while the rear camera needs 90 in a portrait hold. A fixed
        // 90 rendered the front preview a quarter turn out.
        #expect(CameraPreviewRotationPolicy.angle(platformAngle: 0) == 0)
        #expect(CameraPreviewRotationPolicy.angle(platformAngle: 90) == 90)
        #expect(CameraPreviewRotationPolicy.angle(platformAngle: 180) == 180)
        #expect(CameraPreviewRotationPolicy.angle(platformAngle: 270) == 270)
        // An unavailable coordinator keeps the pre-existing fixed angle.
        #expect(CameraPreviewRotationPolicy.angle(platformAngle: nil) == 90)
        #expect(CameraPreviewRotationPolicy.angle(platformAngle: .nan) == 90)
        #expect(CameraPreviewRotationPolicy.fallbackAngle == 90)
    }

    @Test func persistedModeDefaultsAndKey() {
        #expect(CameraPreviewMode.preferenceKey == "camera.previewMode")
        #expect(CameraPreviewMode.allCases == [.neutral, .stock, .log])
        #expect(CameraPreviewMode.resolved(nil) == .neutral)
        #expect(CameraPreviewMode.resolved("normal") == .neutral)
        #expect(CameraPreviewMode.resolved("") == .neutral)
        #expect(CameraPreviewMode.resolved("invalid") == .neutral)
        #expect(CameraPreviewMode.resolved("LOG") == .neutral)
        #expect(CameraPreviewMode.resolved(" log ") == .neutral)
        #expect(CameraPreviewMode.resolved("stock") == .stock)
        #expect(CameraPreviewMode.resolved("log") == .log)
        for mode in CameraPreviewMode.allCases {
            #expect(CameraPreviewMode.resolved(mode.rawValue) == mode)
        }
    }

    @Test func modesResolveExactlyOneLUTFromLog2() {
        let neutralName = "AppleLog2ToRec709.cube"
        let stockName = "5207 - Apple Log 2.cube"
        #expect(CameraPreviewMode.neutral.lutName(for: nil) == neutralName)
        #expect(CameraPreviewMode.neutral.lutName(for: stockName) == neutralName)
        #expect(CameraPreviewMode.stock.lutName(for: nil) == nil)
        #expect(CameraPreviewMode.stock.lutName(for: stockName) == stockName)
        #expect(CameraPreviewMode.log.lutName(for: nil) == nil)
        #expect(CameraPreviewMode.log.lutName(for: stockName) == nil)
    }

    @Test func neutralStockChangesKeepTheSameSelectionGeneration() {
        var selection = CameraPreviewLUTSelection()
        var changed = selection.select(CameraPreviewMode.neutral.lutName(for: nil))
        #expect(changed)
        let neutralRequest = selection
        for stockName in ["5207 - Apple Log 2.cube", "5219 - Apple Log 2.cube"] {
            changed = selection.select(CameraPreviewMode.neutral.lutName(for: stockName))
            #expect(!changed)
            #expect(selection == neutralRequest)
            #expect(selection.generation == neutralRequest.generation)
        }
        changed = selection.select(CameraPreviewMode.stock.lutName(for: "5207 - Apple Log 2.cube"))
        #expect(changed)
        let stockRequest = selection
        changed = selection.select(CameraPreviewMode.neutral.lutName(for: nil))
        #expect(changed)
        #expect(selection != neutralRequest)
        #expect(selection != stockRequest)
        let newNeutralRequest = selection
        changed = selection.select(CameraPreviewMode.log.lutName(for: nil))
        #expect(changed)
        #expect(selection.name == nil)
        #expect(selection != newNeutralRequest)
    }

    @Test func productionParserReadsBundledNeutralCubeWithoutReordering() throws {
        let root = TestRepository.root
        let text = try String(contentsOf: root.appendingPathComponent(
            "App/Resources/Preview/AppleLog2ToRec709.cube"), encoding: .utf8)
        let cube = try CameraPreviewCube.parse(text)
        #expect(cube.size == 33)
        #expect(cube.rgba.count == 33 * 33 * 33 * 4)
        #expect(cube.rgba.allSatisfy { $0.isFinite })
        // Asymmetric grid samples pin production parser RGB/red-fastest indexing.
        let redIndex = ((4 * 33 + 8) * 33 + 16) * 4
        let blueIndex = ((16 * 33 + 8) * 33 + 4) * 4
        let redSample: [Float] = [0.406324685, 0.138296574, 0, 1]
        let blueSample: [Float] = [0, 0.092437297, 0.244335920, 1]
        for channel in 0..<4 {
            #expect(abs(cube.rgba[redIndex + channel] - redSample[channel]) < 0.00001)
            #expect(abs(cube.rgba[blueIndex + channel] - blueSample[channel]) < 0.00001)
        }
    }

    @Test func taggedDisplaySpaceMatchesPreviewGamma24() throws {
        let source = try #require(CGColorSpace(name: CGColorSpace.itur_709))
        let linear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        for value: CGFloat in [0.25, 0.5, 0.75] {
            let color = try #require(CGColor(colorSpace: source, components: [value, value, value, 1]))
            let converted = try #require(color.converted(to: linear, intent: .relativeColorimetric, options: nil))
            let components = try #require(converted.components)
            for component in components.prefix(3) {
                #expect(abs(component - CGFloat(pow(Double(value), 2.4))) < 0.0001)
            }
        }
    }

    @Test func retinaDrawableUsesDisplayScaleNotParentBackingScale() {
        let pixels = CameraPreviewPolicy.drawablePixelSize(viewSize: CGSize(width: 402, height: 874),
            fallbackScale: 1, displayScale: 3)
        #expect(pixels == CGSize(width: 1206, height: 2622))
    }

    @Test func acceptsOnlySupportedFourCCs() {
        let video = CameraPreviewPolicy.PixelFormat(tenBit: true, fullRange: false)
        let full = CameraPreviewPolicy.PixelFormat(tenBit: true, fullRange: true)
        #expect(CameraPreviewPolicy.format(0x78343230) == video) // x420
        #expect(CameraPreviewPolicy.format(0x78343232) == video) // x422
        #expect(CameraPreviewPolicy.format(0x78663230) == full) // xf20
        #expect(CameraPreviewPolicy.format(0x78663232) == full) // xf22
        let unsupportedFormats: [UInt32] = [0, 0x34323076, 0x34323066, 0x42475241, 0x78343434, UInt32.max]
        for unsupported in unsupportedFormats {
            #expect(CameraPreviewPolicy.format(unsupported) == nil)
        }
    }

    @Test func invertsEveryRotationAfterDisplayMirroring() {
        let point = SIMD2<Float>(0.2, 0.7)
        let unmirrored: [SIMD2<Float>] = [
            SIMD2(0.2, 0.7), SIMD2(0.7, 0.8), SIMD2(0.8, 0.3), SIMD2(0.3, 0.2)
        ]
        let mirrored: [SIMD2<Float>] = [
            SIMD2(0.8, 0.7), SIMD2(0.7, 0.2), SIMD2(0.2, 0.3), SIMD2(0.3, 0.8)
        ]
        for turns in 0..<4 {
            expectClose(CameraPreviewPolicy.sourceUV(point, quarterTurns: turns, mirrored: false),
                        unmirrored[turns])
            expectClose(CameraPreviewPolicy.sourceUV(point, quarterTurns: turns, mirrored: true),
                        mirrored[turns])
        }
        expectClose(CameraPreviewPolicy.sourceUV(point, quarterTurns: -1, mirrored: false), unmirrored[3])
        expectClose(CameraPreviewPolicy.sourceUV(point, quarterTurns: 5, mirrored: true), mirrored[1])
        expectClose(CameraPreviewPolicy.sourceUV(point, quarterTurns: 8, mirrored: false), point)
    }

    @Test func mapsCornersWithoutClampingCoordinates() {
        expectClose(CameraPreviewPolicy.sourceUV(SIMD2(0, 0), quarterTurns: 1, mirrored: false), SIMD2(0, 1))
        expectClose(CameraPreviewPolicy.sourceUV(SIMD2(1, 1), quarterTurns: 3, mirrored: true), SIMD2(0, 0))
        expectClose(CameraPreviewPolicy.sourceUV(SIMD2(-0.2, 1.2), quarterTurns: 0, mirrored: false),
                    SIMD2(-0.2, 1.2))
    }

    @Test func fitsAndFillsLandscapeAndPortrait() {
        // Landscape content in a portrait view.
        expectScale(source: SIMD2(400, 200), view: SIMD2(200, 400), turns: 0,
                    fit: SIMD2(1, 0.25), fill: SIMD2(4, 1))
        // Portrait content in a landscape view.
        expectScale(source: SIMD2(200, 400), view: SIMD2(400, 200), turns: 0,
                    fit: SIMD2(0.25, 1), fill: SIMD2(1, 4))
        // Matching portrait and landscape aspect ratios.
        expectScale(source: SIMD2(200, 400), view: SIMD2(100, 200), turns: 0,
                    fit: SIMD2(1, 1), fill: SIMD2(1, 1))
        expectScale(source: SIMD2(400, 200), view: SIMD2(200, 100), turns: 2,
                    fit: SIMD2(1, 1), fill: SIMD2(1, 1))
    }

    @Test func oddTurnsSwapDisplayedAspect() {
        for turns in [1, 3, -1, 5] {
            expectScale(source: SIMD2(400, 200), view: SIMD2(200, 400), turns: turns,
                        fit: SIMD2(1, 1), fill: SIMD2(1, 1))
            expectScale(source: SIMD2(400, 200), view: SIMD2(400, 200), turns: turns,
                        fit: SIMD2(0.25, 1), fill: SIMD2(1, 4))
        }
        for turns in [0, 2, -2, 4] {
            expectScale(source: SIMD2(400, 200), view: SIMD2(200, 400), turns: turns,
                        fit: SIMD2(1, 0.25), fill: SIMD2(4, 1))
        }
    }

    @Test func emptyOrInvalidDimensionsHaveZeroScale() {
        let invalid: [Float] = [0, -1, .infinity, .nan]
        for dimension in invalid {
            for fill in [false, true] {
                let dimensions: [(Float, Float, Float, Float)] = [
                    (dimension, 200, 100, 200), (100, dimension, 100, 200),
                    (100, 200, dimension, 200), (100, 200, 100, dimension)
                ]
                for (sourceWidth, sourceHeight, viewWidth, viewHeight) in dimensions {
                    let scale = CameraPreviewPolicy.imageScale(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                        viewWidth: viewWidth, viewHeight: viewHeight, quarterTurns: 0, fill: fill)
                    #expect(scale == .zero)
                }
            }
        }
    }

    @Test func tenBitVideoBlackWhiteAndNeutral() {
        expectRGB(y: 64, cb: 512, cr: 512, tenBit: true, fullRange: false, expected: SIMD3(repeating: 0))
        expectRGB(y: 940, cb: 512, cr: 512, tenBit: true, fullRange: false, expected: SIMD3(repeating: 1))
        expectRGB(y: 502, cb: 512, cr: 512, tenBit: true, fullRange: false, expected: SIMD3(repeating: 0.5))
    }

    @Test func tenBitFullRangeBlackWhiteAndNeutral() {
        expectRGB(y: 0, cb: 512, cr: 512, tenBit: true, fullRange: true, expected: SIMD3(repeating: 0))
        expectRGB(y: 1023, cb: 512, cr: 512, tenBit: true, fullRange: true, expected: SIMD3(repeating: 1))
        expectRGB(y: 511.5, cb: 512, cr: 512, tenBit: true, fullRange: true, expected: SIMD3(repeating: 0.5))
    }

    @Test func videoColorCodesUseBT2020Coefficients() {
        let expected = SIMD3<Float>(0.5 - 1.4746 * 0.25,
                                    0.5 - 0.164553 * 0.25 + 0.571353 * 0.25,
                                    0.5 + 1.8814 * 0.25)
        expectRGB(y: 502, cb: 736, cr: 288, tenBit: true, fullRange: false, expected: expected)
        expectRGB(y: 125.5, cb: 184, cr: 72, tenBit: false, fullRange: false, expected: expected)
    }

    @Test func fullRangeColorCodesUseFullRangeChromaDivisor() {
        let expected = SIMD3<Float>(511 / 1023 + 1.4746 * (-256 / 1023),
                                    511 / 1023 - 0.164553 * (256 / 1023) - 0.571353 * (-256 / 1023),
                                    511 / 1023 + 1.8814 * (256 / 1023))
        expectRGB(y: 511, cb: 768, cr: 256, tenBit: true, fullRange: true, expected: expected)
    }

    @Test func eightBitBlackWhiteAndNeutral() {
        expectRGB(y: 16, cb: 128, cr: 128, tenBit: false, fullRange: false, expected: SIMD3(repeating: 0))
        expectRGB(y: 235, cb: 128, cr: 128, tenBit: false, fullRange: false, expected: SIMD3(repeating: 1))
        expectRGB(y: 0, cb: 128, cr: 128, tenBit: false, fullRange: true, expected: SIMD3(repeating: 0))
        expectRGB(y: 255, cb: 128, cr: 128, tenBit: false, fullRange: true, expected: SIMD3(repeating: 1))
        expectRGB(y: 127.5, cb: 128, cr: 128, tenBit: false, fullRange: true, expected: SIMD3(repeating: 0.5))
    }

    @Test func conversionDoesNotClampOrDecodeLogTransfer() {
        let rgb = CameraPreviewPolicy.logRGB(y: 940, cb: 960, cr: 64, tenBit: true, fullRange: false)
        #expect(rgb.z > 1)
        expectRGB(y: 64, cb: 512, cr: 64, tenBit: true, fullRange: false,
                  expected: SIMD3(-1.4746 * 0.5, 0.571353 * 0.5, 0))
        expectRGB(y: 0, cb: 512, cr: 512, tenBit: true, fullRange: false,
                  expected: SIMD3(repeating: -64 / 876))
    }

    @Test func shaderMatchesCodeValueAndDisplayContracts() throws {
        // Source-level regression guard only; this does not exercise the GPU.
        let root = TestRepository.root
        let source = try String(contentsOf: root.appendingPathComponent("Resources/Shaders/camera-preview.metal"), encoding: .utf8)
        #expect(source.contains("65535.0 / 64.0"))
        #expect(source.contains("(yCode - 64.0) / 876.0"))
        #expect(source.contains("(u.fullRange ? 1023.0 : 896.0)"))
        #expect(source.contains("y + 1.4746*c.y"))
        #expect(source.contains("y - .164553*c.x - .571353*c.y"))
        #expect(source.contains("y + 1.8814*c.x"))
        #expect(source.contains("float2(uv.y, 1-uv.x)"))
        #expect(source.contains("float2(1-uv.y, uv.x)"))
        #expect(source.contains("lut.sample(linearSampler, coordinates)"))
        #expect(!source.contains("pow("))
        #expect(!source.contains("HLGTo"))
    }

    @Test func expectedLensHandoffDoesNotDisableTheLUTPreview() throws {
        let source = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraView.swift"), encoding: .utf8)
        #expect(!source.contains("active: scenePhase == .active && !viewModel.isSwitchingCameraLens"),
                "An expected lens handoff must not be treated as leaving the active scene")
        #expect(source.contains("transitioning: viewModel.isSwitchingCameraLens"),
                "Pass the expected handoff separately so the preview can retain its last valid image")
    }

    @Test func independentPreviewDoesNotReplaceTheWriter() throws {
        let root = TestRepository.root
        let recorder = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraSampleBufferRecorder.swift"), encoding: .utf8)
        #expect(!recorder.contains("CameraPreviewFrame"))
        #expect(!recorder.contains("previewTap"))
        #expect(recorder.contains("writer.append(sampleBuffer, for: .video)"))
        let session = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraSession.swift"), encoding: .utf8)
        #expect(session.contains("private let previewOutput = AVCaptureVideoDataOutput()"))
        #expect(session.contains("previewOutput.setSampleBufferDelegate(previewTap, queue: previewTap.queue)"))
        #expect(session.contains("videoOutput.setSampleBufferDelegate(sampleBufferRecorder, queue: sampleBufferQueue)"))
        #expect(session.contains("guard let self, self.previewOwner == owner else { return }"))
        #expect(!session.contains("sampleBufferRecorder.suspendPreview"))
        let renderer = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraPreviewRenderer.swift"), encoding: .utf8)
        #expect(renderer.contains("DispatchSemaphore(value: 1)"))
        #expect(renderer.contains("admission.wait(timeout: .now())"))
        #expect(renderer.contains("command.addCompletedHandler"))
        #expect(renderer.contains("withExtendedLifetime(lease)"))
        #expect(!renderer.contains("waitUntilCompleted"))
        #expect(!renderer.contains("CIImage"))
    }

    @Test func previewOutputNegotiatesOnlyItsOwnAdvertisedTenBitSource() throws {
        let root = TestRepository.root
        let session = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraSession.swift"), encoding: .utf8)
        let attachStart = try #require(session.range(of: "private func attachPreviewOutput()"))
        let refreshStart = try #require(session.range(of: "private func refreshPreviewFormat()"))
        let updateStart = try #require(session.range(of: "private func updatePreviewConnection()"))
        let attach = String(session[attachStart.lowerBound..<refreshStart.lowerBound])
        let refresh = String(session[refreshStart.lowerBound..<updateStart.lowerBound])
        #expect(attach.contains("guard session.canAddOutput(previewOutput)"))
        let dimensions = try #require(attach.range(of: "automaticallyConfiguresOutputBufferDimensions = false"))
        let sized = try #require(attach.range(of: "deliversPreviewSizedOutputBuffers = true"))
        #expect(dimensions.lowerBound < sized.lowerBound)
        #expect(attach.contains("session.addOutput(previewOutput)"))
        #expect(refresh.contains("session.outputs.contains(where: { $0 === previewOutput })"))
        #expect(refresh.contains("previewOutput.availableVideoPixelFormatTypes"))
        #expect(refresh.contains("preferredTenBitPixelFormats(from: advertised).first"))
        #expect(refresh.contains("connection.preferredVideoStabilizationMode = .off"))
        #expect(refresh.contains("connection.videoRotationAngle = 0"))
        #expect(refresh.contains("connection.isVideoMirrored = false"))
        for forbidden in ["kCVPixelBufferWidthKey", "kCVPixelBufferHeightKey", "videoOutput.videoSettings",
                          "activeFormat =", "activeColorSpace =", "lockForConfiguration", "beginConfiguration"] {
            #expect(!attach.contains(forbidden))
            #expect(!refresh.contains(forbidden))
        }
        #expect(session.components(separatedBy: "attachPreviewOutput()").count == 3)
        #expect(session.contains("previewOwner != nil && !previewSuspended && isConfigured && session.isRunning"))
        #expect(session.contains("self.suspendPreview(true)"))
        #expect(session.contains("defer { self.suspendPreview(false) }"))
        let tap = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraPreviewTap.swift"), encoding: .utf8)
        #expect(tap.contains("DispatchQueue(label: \"camera.preview.sample-buffer\")"))
        #expect(tap.contains("guard self.owner == owner else { return }"))
        #expect(tap.contains("timestamp >= startAfter"))
        #expect(tap.contains("self.generation == current, !self.receivedFrame"))
        #expect(tap.contains("Camera preview independent source:"))
        #expect(tap.contains("CVPixelBufferGetWidth(buffer)"))
        #expect(tap.contains("CVPixelBufferGetHeight(buffer)"))
        #expect(!tap.contains("writer" + ".append"))
    }

    @Test func selectedLUTTokenOnlyChangesWithFilenameAndRejectsLateLoads() {
        var selection = CameraPreviewLUTSelection()
        var changed = selection.select(nil)
        #expect(!changed)
        changed = selection.select("5207 - Apple Log 2.cube")
        #expect(changed)
        let firstRequest = selection
        changed = selection.select(firstRequest.name)
        #expect(!changed)
        #expect(selection == firstRequest)
        changed = selection.select("5219 - Apple Log 2.cube")
        #expect(changed)
        #expect(selection != firstRequest)
        let secondRequest = selection
        changed = selection.select(firstRequest.name)
        #expect(changed)
        // A -> B -> A must reject the original A completion as well as B.
        #expect(selection != firstRequest)
        #expect(selection != secondRequest)
        changed = selection.select(nil)
        #expect(changed)
        #expect(selection.name == nil)
    }

    @Test func productionParserPreservesAllShippedStockCubeRows() throws {
        let root = TestRepository.root
        let urls = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Resources/LUTs"),
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cube" }
        #expect(urls.count == 8)
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            let cube = try CameraPreviewCube.parse(text)
            #expect(cube.size == 33)
            #expect(cube.rgba.count == 33 * 33 * 33 * 4)
            let rows = text.components(separatedBy: .newlines).compactMap { line -> [Float]? in
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                let floats = parts.compactMap { Float($0) }
                return parts.count == 3 && floats.count == 3 ? floats : nil
            }
            #expect(rows.count == cube.size * cube.size * cube.size)
            // x/red increments first, followed by y/green, then z/blue.
            let expectedRGBA = rows.flatMap { $0 + [Float(1)] }
            #expect(cube.rgba == expectedRGBA)
        }
    }

    @Test func cubeUnitDomainAndStrictStructure() throws {
        let rows = (0..<8).map { index in
            "\(index % 2) \((index / 2) % 2) \((index / 4) % 2)"
        }.joined(separator: "\n")
        let valid = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n" + rows
        let cube = try CameraPreviewCube.parse(valid)
        #expect(Array(cube.rgba[4..<8]) == [1, 0, 0, 1])
        #expect(Array(cube.rgba[8..<12]) == [0, 1, 0, 1])
        #expect(Array(cube.rgba[16..<20]) == [0, 0, 1, 1])
        for invalid in [valid.replacingOccurrences(of: "DOMAIN_MIN 0 0 0", with: "DOMAIN_MIN -1 0 0"),
                        valid.replacingOccurrences(of: "DOMAIN_MAX 1 1 1", with: "DOMAIN_MAX 2 1 1"),
                        valid + "\n1 1 1", "LUT_3D_SIZE 2\n0 0 0",
                        "LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n" + rows,
                        "LUT_3D_SIZE 2\nnan 0 0\n" + rows,
                        "LUT_3D_SIZE 2\n0 0 0 unknown\n" + rows] {
            var rejected = false
            do { _ = try CameraPreviewCube.parse(invalid) } catch { rejected = true }
            #expect(rejected)
        }
    }

    @Test func selectedStockNameReachesQueueOwnedRendererWithoutEffects() throws {
        // Wiring/lifetime source guards complement the pure token/parser tests.
        let root = TestRepository.root
        let content = try String(contentsOf: root.appendingPathComponent("App/ContentView.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("App/Modules/CameraCapture/CameraView.swift"), encoding: .utf8)
        let renderer = try String(contentsOf: root.appendingPathComponent("App/Modules/CameraCapture/CameraPreviewRenderer.swift"), encoding: .utf8)
        let policy = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraPreviewPolicy.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("App/Modules/Purchase/PurchaseView.swift"), encoding: .utf8)
        #expect(content.contains("selectedStockLUTName: selectedStock?.lutName"))
        #expect(view.contains("var selectedStockLUTName: String? = nil"))
        #expect(view.contains("let requested = mode != .log && active"))
        #expect(view.contains("let lutName = mode.lutName(for: selectedStockLUTName)"))
        #expect(view.contains("resolvedLUTName != lutName"))
        #expect(!view.contains("self.selectedStockLUTName != selectedStockLUTName"))
        #expect(view.contains("selectedLUTName: resolvedLUTName"))
        #expect(view.contains("let shouldAttach = wantsLUT && window != nil && renderer != nil"))
        #expect(view.contains("camera.removePreviewTap(owner: owner)"))
        for surface in [view, settings] {
            #expect(surface.contains("@AppStorage(CameraPreviewMode.preferenceKey) private var previewMode = CameraPreviewMode.neutral.rawValue"))
        }
        let neutralOption = try #require(settings.range(of: "Text(\"Neutral\").tag(CameraPreviewMode.neutral)"))
        let stockOption = try #require(settings.range(of: "Text(\"Stock LUT\").tag(CameraPreviewMode.stock)"))
        let logOption = try #require(settings.range(of: "Text(\"Log\").tag(CameraPreviewMode.log)"))
        #expect(neutralOption.lowerBound < stockOption.lowerBound)
        #expect(stockOption.lowerBound < logOption.lowerBound)
        #expect(policy.contains("case .neutral: return \"AppleLog2ToRec709.cube\""))
        #expect(renderer.contains("selection.select(selectedLUTName)"))
        #expect(renderer.contains("if nameChanged { renderQueue.async"))
        #expect(renderer.contains("guard isSelected(requested) else { return }"))
        #expect(renderer.contains("loadedSelection == selected"))
        #expect(renderer.contains("guard let self, self.isCurrentStatus(key, revision: current) else { return }"))
        #expect(renderer.contains("return active && revision == current && publishedStatus == key"))
        #expect(renderer.contains("CameraPreviewCube.parse"))
        #expect(renderer.contains("subdirectory: \"Preview\""))
        #expect(renderer.contains("Preview LUT active [\\(selectedName)]"))
        #expect(!renderer.contains("Stock LUT preview"))
        #expect(renderer.components(separatedBy: "encoder.setFragmentTexture(lut, index: 2)").count == 2)
        #expect(renderer.components(separatedBy: "encoder.drawPrimitives").count == 2)
        for forbidden in ["PipelineRenderer(", "grain", "halation", "toneMapper", "CIImage"] {
            #expect(!renderer.contains(forbidden))
        }
    }

    @Test func aHeldLensHandoffHasAnExplicitNotice() throws {
        let renderer = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraPreviewRenderer.swift"), encoding: .utf8)
        let policy = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraPreviewPolicy.swift"), encoding: .utf8)
        #expect(policy.contains("Switching lenses…"),
                "A held lens switch must be explained instead of silently freezing")
        #expect(renderer.contains("handoff.notice"),
                "The renderer must publish the notice while retaining the graded image")
    }

    @Test func handoffPolicyLensNoticePersistsUntilTheFirstGradedFrame() {
        var policy = CameraPreviewHandoffPolicy()
        _ = policy.graded(at: 0)
        // An explicit lens switch begins the hold and names itself.
        #expect(policy.beginHold(at: 1, lensSwitch: true) == .hold)
        #expect(policy.notice == CameraPreviewHandoffPolicy.lensSwitchText)
        // Completion of the hardware switch alone does not clear the notice.
        #expect(policy.handoffCompleted(at: 2) == .hold)
        #expect(policy.notice == CameraPreviewHandoffPolicy.lensSwitchText)
        // Only the first valid graded frame clears it.
        #expect(policy.graded(at: 3) == .show(nil))
        #expect(policy.notice == nil)
    }

    @Test func handoffPolicyNoticeClearsOnExpiryFatalAndLifecycle() {
        var expired = CameraPreviewHandoffPolicy()
        _ = expired.graded(at: 0)
        _ = expired.beginHold(at: 0, lensSwitch: true)
        #expect(expired.notice == CameraPreviewHandoffPolicy.lensSwitchText)
        #expect(expired.deadlineReached(at: CameraPreviewHandoffPolicy.grace)
                == .show(CameraPreviewHandoffPolicy.sourceUnavailableText))
        #expect(expired.notice == nil)

        var faulted = CameraPreviewHandoffPolicy()
        _ = faulted.graded(at: 0)
        _ = faulted.beginHold(at: 0, lensSwitch: true)
        let gpuError = "Preview LUT GPU error — showing Log"
        #expect(faulted.rejected(.fatal(gpuError), at: 0.1) == .show(gpuError))
        #expect(faulted.notice == nil)

        var left = CameraPreviewHandoffPolicy()
        _ = left.graded(at: 0)
        _ = left.beginHold(at: 0, lensSwitch: true)
        left.invalidate()
        #expect(left.notice == nil)
    }

    @Test func handoffPolicyGenericHoldNeverClaimsALensSwitch() {
        var policy = CameraPreviewHandoffPolicy()
        _ = policy.graded(at: 0)
        // A source reconfiguration or a lost frame is not a lens switch.
        #expect(policy.beginHold(at: 0) == .hold)
        #expect(policy.notice == CameraPreviewHandoffPolicy.updatingPreviewText)
        #expect(policy.notice != CameraPreviewHandoffPolicy.lensSwitchText)
        #expect(policy.suspended(at: 0.1) == .hold)
        #expect(policy.notice == CameraPreviewHandoffPolicy.updatingPreviewText)
        // After recovery a real lens switch names itself again.
        _ = policy.graded(at: 0.2)
        #expect(policy.beginHold(at: 0.3, lensSwitch: true) == .hold)
        #expect(policy.notice == CameraPreviewHandoffPolicy.lensSwitchText)
    }

    @Test func actualLensSwitchRenamesAnExistingGenericHoldWithoutExtendingIt() {
        var policy = CameraPreviewHandoffPolicy()
        _ = policy.graded(at: 0)
        _ = policy.suspended(at: 1)
        let deadline = policy.holdDeadline
        #expect(policy.notice == CameraPreviewHandoffPolicy.updatingPreviewText)
        _ = policy.beginHold(at: 1.1, lensSwitch: true)
        #expect(policy.notice == CameraPreviewHandoffPolicy.lensSwitchText)
        #expect(policy.holdDeadline == deadline)
    }

    @Test func aQueuedInformationalNoticeCannotRestoreAFailedPreview() throws {
        let renderer = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraPreviewRenderer.swift"), encoding: .utf8)
        let start = try #require(renderer.range(of: "private func publish(lutActive:"))
        let end = try #require(renderer.range(of: "private func initialize()"))
        let publication = String(renderer[start.lowerBound..<end.lowerBound])
        #expect(publication.contains("handoff.hasGradableFrame && handoff.notice == warning"),
                "Publishing an informational hold must check the live policy under the publication lock")
        #expect(publication.contains("self.isCurrentStatus(key, revision: current)"),
                "Recheck the queued status on the main thread so a late notice cannot replace a newer error")
    }

    @Test func handoffPolicyNoticeIsNilWhileNoHoldIsLive() {
        var policy = CameraPreviewHandoffPolicy()
        #expect(policy.notice == nil)
        // A cold-start begin publishes pending text and holds nothing.
        #expect(policy.beginHold(at: 0, lensSwitch: true) == .show(CameraPreviewHandoffPolicy.pendingText))
        #expect(policy.notice == nil)
        _ = policy.graded(at: 0)
        #expect(policy.notice == nil)
    }

    @Test func rendererPublishesTheHoldNoticeWhileKeepingTheGradedLayerActive() throws {
        let renderer = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraPreviewRenderer.swift"), encoding: .utf8)
        // A held handoff keeps `lutActive: true` (graded layer retained) and
        // publishes the informational notice read under the lock.
        #expect(renderer.contains("publish(lutActive: true, warning: handoffNotice()"))
        #expect(renderer.contains("return handoff.notice"))
        // A real lens handoff is marked as such; the generic path is not.
        #expect(renderer.contains("lensSwitch: true"))
        #expect(renderer.contains("handoff.beginHold(at: now)"))
        // The publish key includes the notice so active -> holding -> active
        // each delivers.
        #expect(renderer.contains("(lutActive ? \"active:\" : \"log:\") + (warning ?? \"\")"))
    }

    @Test func handoffPolicyHoldsTheLastGradedDrawableThenRecovers() {
        var policy = CameraPreviewHandoffPolicy()
        // Cold start: no graded drawable yet, so a suspension is immediate.
        #expect(policy.beginHold(at: 0) == .show(CameraPreviewHandoffPolicy.pendingText))
        #expect(policy.suspended(at: 0) == .show(CameraPreviewHandoffPolicy.sourceUnavailableText))
        #expect(!policy.isHolding)
        #expect(policy.graded(at: 0.1) == .show(nil))
        // An expected handoff holds the graded drawable and publishes nothing.
        #expect(policy.beginHold(at: 0.2) == .hold)
        #expect(policy.suspended(at: 0.3) == .hold)
        #expect(policy.holdDeadline == 0.2 + CameraPreviewHandoffPolicy.grace)
        // A conforming frame before the deadline recovers cleanly.
        #expect(policy.graded(at: 0.4) == .show(nil))
        #expect(policy.holdDeadline == nil)
        #expect(!policy.isHolding)
    }

    @Test func handoffPolicyNeverExtendsTheDeadlineOnRepeatedBadFrames() {
        var policy = CameraPreviewHandoffPolicy()
        _ = policy.graded(at: 0)
        #expect(policy.beginHold(at: 0) == .hold)
        let deadline = policy.holdDeadline
        #expect(deadline == CameraPreviewHandoffPolicy.grace)
        let unsupported = "Preview LUT unsupported for this source — showing Log"
        // Repeated transitional rejections and suspensions must not move it.
        #expect(policy.rejected(.transitional(unsupported), at: 0.5) == .hold)
        #expect(policy.rejected(.transitional(unsupported), at: 1.0) == .hold)
        #expect(policy.suspended(at: 1.1) == .hold)
        #expect(policy.holdDeadline == deadline)
        // The bounded deadline then publishes the persistent reason.
        #expect(policy.deadlineReached(at: 1.5) == .show(unsupported))
        #expect(!policy.isHolding)
    }

    @Test func handoffPolicyDeadlineSurfacesMissingSourceWhenFramesStop() {
        var policy = CameraPreviewHandoffPolicy()
        _ = policy.graded(at: 0)
        _ = policy.beginHold(at: 0)
        // Before the deadline the hold stands; at it, the missing source shows.
        #expect(policy.deadlineReached(at: 1.4) == .hold)
        #expect(policy.isHolding)
        #expect(policy.deadlineReached(at: 1.5) == .show(CameraPreviewHandoffPolicy.sourceUnavailableText))
        #expect(!policy.isHolding)
    }

    @Test func handoffPolicyExplicitChangesDropTheHeldFrame() {
        var policy = CameraPreviewHandoffPolicy()
        _ = policy.graded(at: 0)
        #expect(policy.beginHold(at: 0) == .hold)
        // Leaving the active scene, entering Log mode, or choosing a new LUT.
        policy.invalidate()
        #expect(!policy.isHolding)
        #expect(!policy.hasGradableFrame)
        // A suspension right after an explicit change is a real condition, not a
        // hold: nothing valid remains to show.
        #expect(policy.suspended(at: 0.1) == .show(CameraPreviewHandoffPolicy.sourceUnavailableText))
    }

    @Test func handoffPolicySurfacesFatalErrorsEvenWhileHolding() {
        var policy = CameraPreviewHandoffPolicy()
        _ = policy.graded(at: 0)
        _ = policy.beginHold(at: 0)
        let gpuError = "Preview LUT GPU error — showing Log"
        #expect(policy.rejected(.fatal(gpuError), at: 0.2) == .show(gpuError))
        #expect(!policy.isHolding)
        // A later conforming frame recovers from the fault.
        #expect(policy.graded(at: 0.5) == .show(nil))
    }

    @Test func handoffPolicyReanchorsOnlyOnCompletedHandoff() {
        var policy = CameraPreviewHandoffPolicy()
        _ = policy.graded(at: 0)
        #expect(policy.beginHold(at: 10) == .hold)
        #expect(policy.holdDeadline == 10 + CameraPreviewHandoffPolicy.grace)
        // Repeated begins (layout churn while a handoff is expected) never extend.
        #expect(policy.beginHold(at: 10.5) == .hold)
        #expect(policy.holdDeadline == 10 + CameraPreviewHandoffPolicy.grace)
        // Completing the handoff restarts the bounded grace from completion.
        #expect(policy.handoffCompleted(at: 11) == .hold)
        #expect(policy.holdDeadline == 11 + CameraPreviewHandoffPolicy.grace)
        #expect(policy.graded(at: 11.2) == .show(nil))
        #expect(policy.holdDeadline == nil)
    }

    @Test func handoffPolicyRapidTransitionsKeepTheLatestDeadline() {
        var policy = CameraPreviewHandoffPolicy()
        _ = policy.graded(at: 0)
        #expect(policy.beginHold(at: 0) == .hold)      // lens A -> B
        #expect(policy.holdDeadline == CameraPreviewHandoffPolicy.grace)
        _ = policy.graded(at: 0.2)                      // B graded
        #expect(policy.beginHold(at: 0.3) == .hold)    // B -> A (rollback)
        #expect(policy.holdDeadline == 0.3 + CameraPreviewHandoffPolicy.grace)
        // A late suspension from the superseded source cannot publish a warning.
        #expect(policy.suspended(at: 0.4) == .hold)
        #expect(policy.deadlineReached(at: 1.8) == .show(CameraPreviewHandoffPolicy.sourceUnavailableText))
    }

    @Test func rendererHoldsTheGradedDrawableThroughAnExpectedHandoff() throws {
        let renderer = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraPreviewRenderer.swift"), encoding: .utf8)
        #expect(renderer.contains("private var handoff = CameraPreviewHandoffPolicy()"))
        #expect(renderer.contains("func configure(active: Bool, transitioning: Bool"))
        #expect(renderer.contains("handoff.beginHold(at:"))
        #expect(renderer.contains("handoff.handoffCompleted(at:"))
        #expect(renderer.contains("handoff.suspended(at:"))
        // A hold publishes nothing; the graded drawable stays on screen.
        #expect(renderer.contains("case .hold"))
        // The bounded deadline is scheduled (not frame-dependent) and only the
        // newest arm may fire, so rapid transitions leave no stale callback.
        #expect(renderer.contains("DispatchQueue.main.asyncAfter"))
        #expect(renderer.contains("token == deadlineToken"))
        let timerStart = try #require(renderer.range(of: "private func deadlineFired(_ token: UInt64)"))
        let timerEnd = try #require(renderer.range(of: "private func isCurrent(_ current: UInt64)"))
        let timer = String(renderer[timerStart.lowerBound..<timerEnd.lowerBound])
        let clearedArm = try #require(timer.range(of: "armedDeadline = nil"),
                                    "A timer that fires slightly early must be able to re-arm")
        let checkedDeadline = try #require(timer.range(of: "handoff.deadlineReached"))
        #expect(clearedArm.lowerBound < checkedDeadline.lowerBound)
        // Real errors are never routed through the holdable transitional path.
        #expect(renderer.contains("reject(.fatal(\"Preview LUT GPU error"))
        #expect(renderer.contains("reject(.transitional(\"Preview LUT unsupported for this source"))
    }

    @Test func previewViewForwardsTheExpectedHandoffSeparately() throws {
        let view = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraView.swift"), encoding: .utf8)
        #expect(view.contains("transitioning: viewModel.isSwitchingCameraLens"))
        #expect(view.contains("uiView.update(mode: mode, active: active, transitioning: transitioning"))
        // A lens change alone must no longer synchronously reset the drawable.
        #expect(!view.contains("activeLens != lens || resolvedLUTName != lutName"))
    }

    private func expectScale(source: SIMD2<Float>, view: SIMD2<Float>, turns: Int,
                             fit: SIMD2<Float>, fill: SIMD2<Float>) {
        expectClose(CameraPreviewPolicy.imageScale(sourceWidth: source.x, sourceHeight: source.y,
            viewWidth: view.x, viewHeight: view.y, quarterTurns: turns, fill: false), fit)
        expectClose(CameraPreviewPolicy.imageScale(sourceWidth: source.x, sourceHeight: source.y,
            viewWidth: view.x, viewHeight: view.y, quarterTurns: turns, fill: true), fill)
    }

    private func expectClose(_ actual: SIMD2<Float>, _ expected: SIMD2<Float>) {
        #expect(abs(actual.x - expected.x) < 0.00001)
        #expect(abs(actual.y - expected.y) < 0.00001)
    }

    private func expectRGB(y: Float, cb: Float, cr: Float, tenBit: Bool, fullRange: Bool,
                           expected: SIMD3<Float>) {
        let actual = CameraPreviewPolicy.logRGB(y: y, cb: cb, cr: cr, tenBit: tenBit, fullRange: fullRange)
        #expect(abs(actual.x - expected.x) < 0.00001)
        #expect(abs(actual.y - expected.y) < 0.00001)
        #expect(abs(actual.z - expected.z) < 0.00001)
    }
}
