import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

struct ManualControlsOverlayTests {
    /// Supersedes the old bounce-tuning contract: the manual face must not have
    /// a scroll viewport at all, so a lower control can never sit below a scrolled
    /// fold. Fitting is proven by the native geometry regression below.
    @Test func manualPanelHasNoScrollViewport() throws {
        let root = TestRepository.root
        for path in ["App/Modules/CameraCapture/ManualControlsOverlay.swift",
                     "App/Modules/CameraCapture/ManualControlsSurface.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("ScrollView"),
                    "\(path) must fit its controls inside the granted face, not scroll to reach them.")
            #expect(!source.contains("scrollBounceBehavior"),
                    "Bounce tuning only applies to a scroll viewport that no longer exists.")
        }
    }

    @Test func compactFootprintIsNotAvailableViewportSlab() {
        let rect = ManualControlsOverlayGeometry.rect(viewport: CGSize(width: 390, height: 763),
                                                      toolbarBottom: 60, controlsTop: 580)
        #expect(rect.width <= 304)
        #expect(rect.height <= 214)
    }

    @MainActor @Test func compactFaceAndActualTextRowsSaveVerticalSpace() throws {
        for degrees in [0.0, 90.0, -90.0] {
            let face = ManualControlsOverlayGeometry.faceSize(expanded: false, rotationDegrees: degrees)
            #expect(face.height <= 170,
                    "Slow-zoom controls must fit inside the dense compact face.")
        }
        let snapshot = CameraStabilizationSnapshot(preferred: .standard,
                                                   capability: .init(connectionSupported: true, formatModes: [.standard]),
                                                   activeRawValue: 1, cameraRevision: 1, changesAllowed: true)
        let compact = ManualControlsSurface(zoom: .constant(2), focus: .constant(0.5),
                                            manualFocus: .constant(true), expanded: .constant(false),
                                            landscape: false, zoomRange: 1...8,
                                            exposure: "ISO 800 · 1/48", apertureReadout: "f/1.8",
                                            stabilization: snapshot, canChangeStabilization: true,
                                            selectStabilization: { _ in }, dismiss: {}) { Text("IRIS") }
        let host = NSHostingView(rootView: compact.frame(width: 304))
        #expect(host.fittingSize.height <= 170, "Native compact content must fit without scrolling at its normal width.")

        // Inspect the actual label/readout declarations, not only a smaller clipping viewport.
        let root = TestRepository.root
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/ManualControlsSurface.swift"), encoding: .utf8)
        #expect(source.contains("private var compactTextRowHeight: CGFloat { 18 }"))
        #expect(source.contains("private var rowHeight: CGFloat { expandedLayout ? 44 : compactTextRowHeight }"),
                "Labels and readouts must share the compact row height when not expanded.")
        #expect(source.components(separatedBy: ".frame(height: rowHeight)").count == 3,
                "Labels and readouts need genuinely smaller rows, not only a shorter face.")
        #expect(source.contains(".frame(maxWidth: .infinity, minHeight: 44)"),
                "Interactive AF/MF and mode rows must retain 44pt targets.")
    }

    /// Native fitting regression (added before the scroll-free rewrite): the real
    /// surface must render inside the granted face without a scroll viewport, and
    /// its lowest control must stay visible rather than clipped below a scrolled
    /// fold. Expanded is asserted where the face can hold it; genuinely short
    /// faces fall back to the compact face, which this asserts still fits.
    @MainActor @Test func nativePanelFitsItsGrantedFaceWithoutScrolling() throws {
        let snapshot = CameraStabilizationSnapshot(
            preferred: .standard,
            capability: .init(connectionSupported: true, formatModes: [.standard, .cinematic, .extreme]),
            activeRawValue: 1, cameraRevision: 1, changesAllowed: true)
        func surface(expanded: Bool, landscape: Bool) -> ManualControlsSurface<Text> {
            ManualControlsSurface(zoom: .constant(2.3), focus: .constant(0.6),
                                  manualFocus: .constant(true), expanded: .constant(expanded),
                                  landscape: landscape, zoomRange: 1...8,
                                  exposure: "ISO 800 · 1/48", apertureReadout: "f/1.8",
                                  stabilization: snapshot, canChangeStabilization: true,
                                  selectStabilization: { _ in }, dismiss: {}) { Text("IRIS") }
        }
        for size in [CGSize(width: 402, height: 874), CGSize(width: 390, height: 844),
                     CGSize(width: 430, height: 932), CGSize(width: 320, height: 568)] {
            for degrees in [0.0, 90.0, -90.0] {
                let landscape = degrees != 0
                let status = RecordingStatusOverlayGeometry.rect(viewport: size, toolbarBottom: 110,
                                                                 controlsTop: size.height - 180, rotationDegrees: degrees)
                let rect = ManualControlsOverlayGeometry.rect(viewport: size, toolbarBottom: 110,
                                                              controlsTop: size.height - 180, excluding: status,
                                                              expanded: true, rotationDegrees: degrees)
                let face = CGSize(width: landscape ? rect.height : rect.width,
                                  height: landscape ? rect.width : rect.height)
                // Mirrors ManualControlsLayout's bounded expanded minimum.
                let expandedMinimum: CGFloat = landscape ? 300 : 326
                let expandedFits = face.height >= expandedMinimum
                let host = NSHostingView(rootView: surface(expanded: expandedFits, landscape: landscape)
                    .frame(width: face.width))
                #expect(host.fittingSize.height <= face.height + 0.5,
                        "The real \(landscape ? "landscape" : "portrait") surface must fit its \(Int(face.height))pt face on \(Int(size.width))x\(Int(size.height)) without scrolling.")

                let overlay = ManualControlsOverlay(viewport: size, toolbarBottom: 110,
                                                    controlsTop: size.height - 180, excluding: status,
                                                    expanded: true, rotationDegrees: degrees) {
                    surface(expanded: true, landscape: landscape)
                }
                let image = try bitmap(overlay, size: size)
                let ink = try whiteInk(image)
                #expect(ink.count > 400, "The real manual face must render visible native controls, not a blank placeholder.")
                let scale = CGFloat(image.width) / size.width
                let bounds = rect.insetBy(dx: -1, dy: -1)
                #expect(ink.allSatisfy { bounds.contains(CGPoint(x: CGFloat($0.x) / scale,
                                                                 y: CGFloat($0.y) / scale)) },
                        "No control may render outside the granted face; nothing scrolls into view.")
                if degrees == 0, expandedFits {
                    let rows = ink.map { CGFloat($0.y) / scale }
                    #expect(rows.contains { $0 >= rect.minY && $0 <= rect.minY + 50 },
                            "The header row must be visible inside the face.")
                    #expect(rows.contains { $0 >= rect.maxY - 60 && $0 <= rect.maxY },
                            "The lowest control row must be visible inside the face, not clipped below a fold.")
                }
                try save(image, name: "fitting-\(Int(size.width))x\(Int(size.height))-\(Int(degrees))")
            }
        }
    }

    /// The bounded fallback: a requested expanded face is used only when the
    /// granted height can hold it; otherwise the compact face fits instead.
    @Test func expandedFaceIsBoundedByGrantedHeightNotByRequest() {
        #expect(ManualControlsLayout.usesExpanded(requested: true, landscape: false, availableHeight: 330))
        #expect(ManualControlsLayout.usesExpanded(requested: true, landscape: false, availableHeight: 326))
        #expect(!ManualControlsLayout.usesExpanded(requested: true, landscape: false, availableHeight: 128))
        #expect(ManualControlsLayout.usesExpanded(requested: true, landscape: true, availableHeight: 306))
        #expect(!ManualControlsLayout.usesExpanded(requested: true, landscape: true, availableHeight: 248))
        #expect(!ManualControlsLayout.usesExpanded(requested: false, landscape: false, availableHeight: 330))
        // Hosted standalone (no granted face) keeps the requested layout.
        #expect(ManualControlsLayout.usesExpanded(requested: true, landscape: false, availableHeight: nil))
    }

    @MainActor @Test func defaultOverlayDoesNotStretchIntoAvailableSlab() throws {
        let view = ManualControlsOverlay(viewport: CGSize(width: 390, height: 763),
                                         toolbarBottom: 60, controlsTop: 580) {
            // Use literal RGB: the semantic system red varies with appearance
            // and can exceed this test's deliberately strict green threshold.
            Text("MANUAL").frame(maxWidth: .infinity).frame(height: 100)
                .background(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
        }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 763)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try save(#require(rep.cgImage), name: "compact-marker-host")
        let redColumns = (0..<rep.pixelsWide).filter { x in
            (0..<rep.pixelsHigh).contains { y in
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.8 && color.greenComponent < 0.2
            }
        }
        #expect(redColumns.count > 100)
        #expect(redColumns.count <= Int(304 * CGFloat(rep.pixelsWide) / 390),
                "Compact overlay must not stretch to the full 358pt available width.")
    }

    @Test func productionPanelKeepsHardwareBindingsAndSingleOuterRotation() throws {
        let root = TestRepository.root
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let panel = try source("App/Modules/CameraCapture/ManualControlsPanel.swift")
        let surface = try source("App/Modules/CameraCapture/ManualControlsSurface.swift")
        let overlay = try source("App/Modules/CameraCapture/ManualControlsOverlay.swift")
        let screen = try source("App/ContentView.swift")
        #expect(panel.contains("cameraViewModel.setDisplayZoom($0)"))
        #expect(panel.contains("beginZoom: cameraViewModel.beginSlowZoom"))
        #expect(panel.contains("endZoom: cameraViewModel.endSlowZoom(revision:)"))
        #expect(surface.contains("zoomHold(.out") && surface.contains("zoomHold(.in"))
        #expect(panel.contains("guard isManualFocus else { return }"))
        #expect(panel.contains("cameraViewModel.session.setManualFocusPosition(Float(manualFocusPosition))"))
        #expect(panel.contains("cameraViewModel.session.resetAutoFocus()"))
        #expect(panel.contains("canChangeStabilization: cameraViewModel.canSetRecordingStabilization"))
        #expect(panel.contains("selectStabilization: cameraViewModel.setRecordingStabilization"))
        #expect(panel.contains("cameraViewModel.setLensAperture(nil)"))
        #expect(panel.contains("cameraViewModel.setLensAperture(stop)"))
        #expect(!panel.contains("cameraUpright") && !surface.contains("cameraUpright"))
        #expect(overlay.components(separatedBy: ".rotationEffect(").count == 2)
        #expect(screen.contains("@AppStorage(\"camera.manualControlsExpanded\") private var manualControlsExpanded = false"))
        #expect(screen.contains("expanded: manualControlsExpanded,"))
        #expect(screen.contains("expanded: $manualControlsExpanded,"))
        #expect(screen.contains("landscape: abs(statusRotationDegrees) == 90"))
        #expect(surface.contains("@AppStorage(\"camera.manualControlsLastEnabledStabilization\")"))
    }

    @MainActor @Test func sharedControlActionsChangeBindingsAndGateModeCallbacks() {
        var expanded = false
        var manual = false
        var requested: [CameraStabilizationMode] = []
        let snapshot = CameraStabilizationSnapshot(preferred: .cinematic,
                                                   capability: .init(connectionSupported: true, formatModes: [.cinematic]),
                                                   activeRawValue: 2, cameraRevision: 1, changesAllowed: true)
        let surface = ManualControlsSurface(
            zoom: .constant(2), focus: .constant(0.6),
            manualFocus: Binding(get: { manual }, set: { manual = $0 }),
            expanded: Binding(get: { expanded }, set: { expanded = $0 }), landscape: false,
            zoomRange: 1...8, exposure: "ISO 800 · 1/48", apertureReadout: "f/1.8",
            stabilization: snapshot, canChangeStabilization: true,
            selectStabilization: { requested.append($0) }, dismiss: {}, aperture: { EmptyView() })
        surface.toggleExpanded()
        #expect(expanded && !manual)
        surface.toggleFocus()
        #expect(expanded && manual)
        surface.toggleExpanded()
        surface.toggleFocus()
        #expect(!expanded && !manual)
        surface.setStabilizationEnabled(false)
        surface.setStabilizationEnabled(true)
        surface.selectMode(.extreme)
        surface.selectMode(.cinematic)
        #expect(requested == [.off, .cinematic, .cinematic])
        #expect(surface.stabilization.preferred == .cinematic, "Requests must not optimistically mutate camera readback.")
        let locked = ManualControlsSurface(
            zoom: .constant(2), focus: .constant(0.6), manualFocus: .constant(false), expanded: .constant(false),
            landscape: true, zoomRange: 1...8, exposure: "ISO 800 · 1/48", apertureReadout: "f/1.8",
            stabilization: snapshot, canChangeStabilization: false,
            selectStabilization: { requested.append($0) }, dismiss: {}, aperture: { EmptyView() })
        locked.setStabilizationEnabled(false)
        locked.selectMode(.cinematic)
        #expect(requested == [.off, .cinematic, .cinematic])
    }

    @Test func stabilizationToggleRetainsModeButRejectsUnsupportedAndTransitionRequests() {
        let supported = CameraStabilizationPolicy.Capability(connectionSupported: true,
                                                            formatModes: [.standard, .cinematic, .extreme])
        let off = CameraStabilizationSnapshot(preferred: .off, capability: supported,
                                              activeRawValue: 0, cameraRevision: 1, changesAllowed: true)
        #expect(ManualStabilizationSelection.toggleTarget(enabled: true, snapshot: off, remembered: .extreme) == .extreme)
        #expect(ManualStabilizationSelection.toggleTarget(enabled: false, snapshot: off, remembered: .extreme) == .off)
        let unavailable = CameraStabilizationSnapshot(preferred: .extreme, capability: .unavailable,
                                                      activeRawValue: 0, cameraRevision: 2, changesAllowed: true)
        #expect(ManualStabilizationSelection.toggleTarget(enabled: true, snapshot: unavailable, remembered: .extreme) == nil)
        #expect(unavailable.preferred == .extreme && unavailable.active == .off)
        let fallback = CameraStabilizationSnapshot(preferred: .off,
                                                   capability: .init(connectionSupported: true, formatModes: [.cinematic]),
                                                   activeRawValue: 0, cameraRevision: 3, changesAllowed: true)
        #expect(ManualStabilizationSelection.toggleTarget(enabled: true, snapshot: fallback, remembered: .extreme) == .cinematic)
        let locked = CameraStabilizationSnapshot(preferred: .cinematic, capability: supported,
                                                 activeRawValue: 2, cameraRevision: 4, changesAllowed: false)
        #expect(ManualStabilizationSelection.toggleTarget(enabled: false, snapshot: locked, remembered: .cinematic) == nil)
        #expect(ManualStabilizationSelection.toggleTarget(enabled: true, snapshot: locked, remembered: .cinematic) == nil)
    }

    @Test func landscapeManualPanelPinsToPhysicalBottomOppositeTimer() throws {
        for size in [CGSize(width: 320, height: 480), CGSize(width: 390, height: 763),
                     CGSize(width: 430, height: 850)] {
            for degrees in [90.0, -90.0] {
                for expanded in [false, true] {
                    let timer = try #require(RecordingStatusOverlayGeometry.rect(
                        viewport: size, toolbarBottom: 110, controlsTop: size.height - 180,
                        rotationDegrees: degrees))
                    let available = ManualControlsOverlayGeometry.availableRect(
                        viewport: size, toolbarBottom: 110, controlsTop: size.height - 180,
                        excluding: timer)
                    let panel = ManualControlsOverlayGeometry.rect(
                        viewport: size, toolbarBottom: 110, controlsTop: size.height - 180,
                        excluding: timer, expanded: expanded, rotationDegrees: degrees)
                    #expect(!panel.intersects(timer))
                    if degrees > 0 {
                        #expect(panel.minX == available.minX,
                                "A +90° face belongs on portrait left, the physical bottom.")
                    } else {
                        #expect(panel.maxX == available.maxX,
                                "A -90° face belongs on portrait right, the physical bottom.")
                    }
                    let physicalTurn = CGAffineTransform(rotationAngle: -degrees * .pi / 180)
                    let panelEdge = CGPoint(x: panel.midX - size.width / 2, y: 0).applying(physicalTurn)
                    let timerEdge = CGPoint(x: timer.midX - size.width / 2, y: 0).applying(physicalTurn)
                    #expect(panelEdge.y > timerEdge.y,
                            "In both physical holds the manual panel must sit below the timer.")
                }
            }
        }
    }

    @Test func wholeFaceReservesTurnedBoundsAndStatusRail() {
        for size in [CGSize(width: 320, height: 430), CGSize(width: 390, height: 763), CGSize(width: 430, height: 820)] {
            for expanded in [false, true] {
                for degrees in [0.0, 90.0, -90.0] {
                    let status = RecordingStatusOverlayGeometry.rect(viewport: size, toolbarBottom: 110,
                                                                      controlsTop: size.height - 180, rotationDegrees: degrees)
                    let rect = ManualControlsOverlayGeometry.rect(viewport: size, toolbarBottom: 110,
                                                                  controlsTop: size.height - 180, excluding: status,
                                                                  expanded: expanded, rotationDegrees: degrees)
                    #expect(rect.minX >= 16 && rect.maxX <= size.width - 16)
                    #expect(rect.minY >= 116 && rect.maxY <= size.height - 186)
                    if let status { #expect(!rect.intersects(status)) }
                    let face = ManualControlsOverlayGeometry.faceSize(expanded: expanded, rotationDegrees: degrees)
                    #expect(rect.width <= (degrees == 0 ? face.width : face.height))
                    #expect(rect.height <= (degrees == 0 ? face.height : face.width))
                }
            }
        }
    }

    @MainActor @Test func actualSharedControlsRenderInsideSafeViewportInEveryHold() throws {
        for size in [CGSize(width: 320, height: 430), CGSize(width: 390, height: 763), CGSize(width: 430, height: 820)] {
            for expanded in [false, true] {
                for degrees in [0.0, 90.0, -90.0] {
                    let status = RecordingStatusOverlayGeometry.rect(viewport: size, toolbarBottom: 110,
                                                                      controlsTop: size.height - 180, rotationDegrees: degrees)
                    let rect = ManualControlsOverlayGeometry.rect(viewport: size, toolbarBottom: 110,
                                                                  controlsTop: size.height - 180, excluding: status,
                                                                  expanded: expanded, rotationDegrees: degrees)
                    let snapshot = CameraStabilizationSnapshot(preferred: .extreme,
                                                               capability: .init(connectionSupported: true,
                                                                                 formatModes: [.standard, .cinematic, .extreme]),
                                                               activeRawValue: 0, cameraRevision: 1, changesAllowed: true)
                    let overlay = ManualControlsOverlay(viewport: size, toolbarBottom: 110,
                                                         controlsTop: size.height - 180, excluding: status,
                                                         expanded: expanded, rotationDegrees: degrees) {
                        ManualControlsSurface(zoom: .constant(2.3), focus: .constant(0.6), manualFocus: .constant(true),
                                              expanded: .constant(expanded), landscape: degrees != 0, zoomRange: 1...8,
                                              exposure: "ISO 800 · 1/48", apertureReadout: "f/1.8",
                                              stabilization: snapshot, canChangeStabilization: true,
                                              selectStabilization: { _ in }, dismiss: {}) {
                            Image(systemName: "lock.fill")
                        }
                    }
                    let image = try bitmap(overlay.padding(24), size: CGSize(width: size.width + 48, height: size.height + 48))
                    let scale = CGFloat(image.width) / (size.width + 48)
                    let ink = try whiteInk(image)
                    #expect(ink.count > 200, "Native shared controls must be nonblank, not just an overlay marker.")
                    let bounds = rect.offsetBy(dx: 24, dy: 24).insetBy(dx: -1, dy: -1)
                    #expect(ink.allSatisfy { bounds.contains(CGPoint(x: CGFloat($0.x) / scale, y: CGFloat($0.y) / scale)) },
                            "Actual controls must be clipped below toolbar, above shooting keys, and outside the status rail.")
                    let name = "shared-manual-\(Int(size.width))-\(expanded ? "expanded" : "compact")-\(Int(degrees))"
                    try save(image, name: name)
                    if degrees != 0 {
                        let upright = try bitmap(overlay.rotationEffect(.degrees(-degrees))
                            .frame(width: size.height, height: size.width).padding(24),
                            size: CGSize(width: size.height + 48, height: size.width + 48))
                        try save(upright, name: name + "-physical")
                    }
                }
            }
        }
    }

    @MainActor @Test func landscapeNativeSliderHasHorizontalUprightAxis() throws {
        let track = ManualControlTrack(value: .constant(0.6), range: 0...1, step: 0.01,
                                       landscape: true, length: 56, label: "Focus")
        let image = try bitmap(track.padding(12), size: CGSize(width: 184, height: 80))
        let ink = try whiteInk(image)
        let xs = ink.map(\.x), ys = ink.map(\.y)
        let width = try #require(xs.max()) - #require(xs.min())
        let height = try #require(ys.max()) - #require(ys.min())
        #expect(width > height * 2, "Landscape uses the native horizontal Slider, not a turned portrait track.")
        try save(image, name: "shared-manual-landscape-slider-axis")
    }

    @MainActor private func bitmap<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    private func whiteInk(_ image: CGImage) throws -> [(x: Int, y: Int)] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).compactMap { index in
            guard pixels[index] > 220, pixels[index + 1] > 220, pixels[index + 2] > 220,
                  pixels[index + 3] > 220 else { return nil }
            return ((index / 4) % image.width, (index / 4) / image.width)
        }
    }

    private func save(_ image: CGImage, name: String) throws {
        let directory = TestRepository.artifactDirectory("compact-manual-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func panelGeometryUsesOnlyAvailableViewportAndStationaryChrome() {
        for size in [CGSize(width: 320, height: 430), CGSize(width: 390, height: 763), CGSize(width: 430, height: 820)] {
            for toolbar: CGFloat in [52, 154, 174] {
                let rect = ManualControlsOverlayGeometry.availableRect(viewport: size, toolbarBottom: toolbar,
                                                              controlsTop: size.height - 180)
                #expect(rect.minX == 16 && rect.maxX == size.width - 16)
                #expect(rect.minY == toolbar + 6)
                #expect(rect.maxY <= size.height - 186)
                #expect(rect.height >= 0)
            }
        }
        let noSpace = ManualControlsOverlayGeometry.rect(viewport: CGSize(width: 320, height: 200),
                                                         toolbarBottom: 180, controlsTop: 100)
        #expect(noSpace.height == 0)
    }

    @MainActor @Test func tallPanelStaysBelowToolbarInsideShortAndNarrowViewports() throws {
        for size in [CGSize(width: 320, height: 430), CGSize(width: 390, height: 763), CGSize(width: 430, height: 820)] {
            for degrees in [0.0, 90.0, -90.0] {
                let top: CGFloat = 110
                let bottom = size.height - 180
                let view = ManualControlsOverlay(
                    viewport: size, toolbarBottom: top, controlsTop: bottom
                ) {
                    VStack {
                        Text("MANUAL").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .fixedSize()
                            .rotationEffect(.degrees(degrees))
                            .frame(width: 80, height: 80)
                        Color.red.frame(height: 900)
                        Text("Stabilization help").rotationEffect(.degrees(degrees))
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                }.padding(32)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: CGSize(width: size.width + 64, height: size.height + 64))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = try #require(bitmap.cgImage)
                let scale = CGFloat(image.width) / (size.width + 64)
                #expect(CGFloat(image.height) == (size.height + 64) * scale)
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                        space: CGColorSpaceCreateDeviceRGB(),
                                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                let ink = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 160 && pixels[$0 + 1] < 100 }
                let xs = ink.map { ($0 / 4) % image.width }
                let ys = ink.map { ($0 / 4) / image.width }
                #expect(ink.count > 10_000, "The manual surface must actually be visible.")
                #expect(try #require(xs.min()) >= Int(48 * scale))
                #expect(try #require(xs.max()) < Int((size.width + 16) * scale))
                #expect(try #require(ys.min()) >= Int((top + 38) * scale))
                #expect(try #require(ys.max()) < Int((bottom + 32) * scale))
                let glyphInk = stride(from: 0, to: pixels.count, by: 4).filter {
                    pixels[$0] > 220 && pixels[$0 + 1] > 220 && pixels[$0 + 2] > 220 && pixels[$0 + 3] > 220
                }
                #expect(glyphInk.count > 60, "The rotated manual header must retain visible native ink.")
                let glyphRows = glyphInk.map { ($0 / 4) / image.width }
                #expect(try #require(glyphRows.min()) >= Int((top + 38) * scale))
                #expect(try #require(glyphRows.max()) < Int((bottom + 32) * scale))
                let directory = TestRepository.artifactDirectory("camera-design-renders")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("manual-\(Int(size.width))-\(degrees).png")
                let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
            }
        }
    }
}
