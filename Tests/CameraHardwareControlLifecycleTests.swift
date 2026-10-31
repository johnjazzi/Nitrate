import Foundation
import Testing

/// Behavioural contracts for the Camera Control slider's lifecycle and value
/// synchronisation, exercised against the pure presentation rules this target
/// compiles. (Presenting a real `AVCaptureSlider` needs an iPhone with Camera
/// Control, so nothing here proves the hardware shows a control.)
struct CameraHardwareControlLifecycleTests {
    /// A slider only exists while its graph runs, so a request retained during a
    /// stopped graph installs nothing. That is the cold-launch/foreground shape:
    /// without a re-apply at the start boundary the button keeps no slider.
    @Test func stoppedGraphInstallsNothingSoStartMustReapply() {
        let range = CameraHardwareControlPolicy.sliderRange(
            for: .zoom, zoom: 1...4, exposure: -3...3)
        #expect(range == 1...4)

        let stopped = CameraHardwareControlPolicy.selectedAdjustment(
            .zoom, supportsControls: false, range: range)
        #expect(stopped == nil)
        #expect(CameraHardwareControlPolicy.step(installed: nil, selected: stopped) == .none)

        let running = CameraHardwareControlPolicy.selectedAdjustment(
            .zoom, supportsControls: true, range: range)
        #expect(running == .zoom)
        #expect(CameraHardwareControlPolicy.step(installed: nil, selected: running) == .install(.zoom))
    }

    /// Eligibility must not claim an exposure slide the session would refuse:
    /// a single-position EV window presents no exposure slider.
    @Test func unusableEVRangePresentsNoExposureSlider() {
        #expect(CameraHardwareControlPolicy.sliderRange(
            for: .exposure, zoom: 1...4, exposure: 0...0) == nil)
        #expect(CameraHardwareControlPolicy.sliderRange(
            for: .exposure, zoom: 1...4, exposure: -0.0001...0.0001) == nil)
        #expect(CameraHardwareControlPolicy.sliderRange(
            for: .exposure, zoom: 1...4, exposure: -1...2) == -1...2)
        #expect(CameraHardwareControlPolicy.minimumRangeSpan > 0)
    }

    /// The value carried by a retained request is clamped into the live device
    /// range, never written through as-is after a lens or profile change.
    @Test func retainedValueIsClampedIntoTheLiveRange() {
        #expect(CameraHardwareControlPolicy.sliderValue(
            for: .zoom, zoomValue: 9, exposureValue: 0,
            zoomRange: 1...4, exposureRange: -3...3) == 4)
        #expect(CameraHardwareControlPolicy.sliderValue(
            for: .exposure, zoomValue: 1, exposureValue: 6,
            zoomRange: 1...4, exposureRange: -3...3) == 3)
    }
}

/// Source contracts for the wiring the behavioural rules cannot reach: the
/// capture sources themselves are read as text and are not evidence of a slider
/// on device. Each expectation names the path it protects.
struct CameraHardwareControlLifecycleSourceContractTests {
    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relativePath),
                   encoding: .utf8)
    }

    /// Body of the first declaration after `marker`, resolved by brace matching,
    /// so each start site is checked on its own instead of by global substring.
    private func body(after marker: String, in text: String) throws -> String {
        let start = try #require(text.range(of: marker))
        let remainder = text[start.upperBound...]
        let open = try #require(remainder.firstIndex(of: "{"))
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        throw ExtractionError.unbalanced(marker)
    }

    private enum ExtractionError: Error { case unbalanced(String) }

    /// Every path that really starts the session re-applies the retained request,
    /// and it does so through one helper that reuses `publishZoom()` rather than
    /// creating a second framework path.
    @Test func everyRealStartReappliesTheRetainedRequest() throws {
        let session = try source("App/Modules/CameraCapture/CameraSession.swift")
        let helper = try body(after: "private func refreshHardwareControlsAfterStartOnQueue()", in: session)
        #expect(helper.contains("guard session.isRunning"))
        #expect(helper.contains("publishZoom()"))
        #expect(!helper.contains("hardwareControls.apply("))

        for startSite in ["func start()",
                          "func reconcileLifecycle()",
                          "func resetVideoSessionAtSafeBoundary()",
                          "func installSharedIdleOnQueue()"] {
            let site = try body(after: startSite, in: session)
            #expect(site.contains("refreshHardwareControlsAfterStartOnQueue()"),
                    "\(startSite) must re-apply the retained request after it starts the session")
            #expect(site.contains("startRunning()"), "\(startSite) is a real start boundary")
        }

        // The refresh follows the real start, not precedes it.
        let idle = try body(after: "private func installSharedIdleOnQueue()", in: session)
        let startIndex = try #require(idle.range(of: "startRunning()"))
        let refreshIndex = try #require(idle.range(of: "refreshHardwareControlsAfterStartOnQueue()"))
        #expect(startIndex.lowerBound < refreshIndex.lowerBound)
    }

    /// Applying a retained request must use the snapshot just built, or it writes
    /// the previous zoom back into the slider.
    @Test func publishRefreshesTheRequestFromTheSnapshotItJustBuilt() throws {
        let session = try source("App/Modules/CameraCapture/CameraSession.swift")
        let publish = try body(after: "private func publishZoom()", in: session)
        #expect(publish.contains("if !request.usesNativeIdlePreview, let snapshot"))
        #expect(publish.contains("request.displayZoom = snapshot.displayFactor"))

        // The native idle crop is deliberately kept: the device reading cannot
        // express Photo's software magnification.
        let nativeIdle = try #require(publish.range(of: "if !request.usesNativeIdlePreview, let snapshot"))
        let apply = try #require(publish.range(of: "hardwareControls.apply("))
        #expect(nativeIdle.lowerBound < apply.lowerBound)
    }

    /// Photo's crop magnification and Video's displayed magnification keep their
    /// separate sources in the request the UI pushes.
    @Test func idleCropValueSurvivesTheRequest() throws {
        let model = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        let push = try body(after: "private func pushCameraHardwareControls()", in: model)
        #expect(push.contains("photoCropZoom * (zoomSnapshot?.displayMultiplier ?? 1)"))
        #expect(push.contains("zoomSnapshot?.displayFactor ?? 1"))
        #expect(push.contains("usesNativeIdlePreview: usesNativeIdlePreview"))
        // EV stays our authoritative intent; the device bias is not authoritative
        // while the shutter is pinned.
        #expect(push.contains("exposureBias: liveExposureBias"))
        #expect(!push.contains("exposureTargetBias"))
    }

    /// The runtime capture gate the screen calls at fire time mirrors the graph,
    /// and deliberately lets an active or starting take receive its stop/cancel.
    @Test func captureGateMirrorsTheRuntimeGraph() throws {
        let model = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        let gate = try body(after: "var canAcceptHardwareCapture: Bool", in: model)
        #expect(gate.contains("cameraConfigured"))
        #expect(gate.contains("lifecycleGate.isActive"))
        #expect(gate.contains("areHardwareControlsRequested"))
        #expect(gate.contains("!isPhotoCaptureBusy"))
        #expect(gate.contains("!isChangingFrameRate"))
        #expect(gate.contains("!isChangingCaptureProfile"))
        #expect(gate.contains("!isSwitchingCameraLens"))
        #expect(!gate.contains("!isRecording"))
        #expect(!gate.contains("!isStartingRecording"))
        let admitsTakeCancellation = gate.contains("if isRecording || isStartingRecording { return true }")
        #expect(admitsTakeCancellation)
    }

    /// Exposure eligibility mirrors the touch path: a held manual ISO is excluded
    /// because the device bias is inert in custom exposure mode, shutter priority
    /// is not (its EV re-pins the metered ISO), and Photo keeps the still
    /// controller's own ISO/shutter hold rule.
    @Test func exposureEligibilityMirrorsTheTouchPath() throws {
        let model = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        #expect(model.contains("var isManualExposure = false { didSet { pushCameraHardwareControls() } }"))

        // The exposure policy lives on the stable presentation half; write
        // eligibility is that half ANDed with the transient capture gate.
        let eligible = try body(after: "private var areHardwareControlsPresented: Bool", in: model)
        #expect(eligible.contains("!isRecording && canAdjustEVThroughCurrentPath && hasUsableExposureBiasRange"))

        let path = try body(after: "private var canAdjustEVThroughCurrentPath: Bool", in: model)
        #expect(path.contains("return !isManualExposure"))
        #expect(path.contains("snapshot.isoLocked && snapshot.shutterLocked"))

        // A Photo hold change re-pushes eligibility on its own.
        let snapshot = try body(after: "private(set) var photoExposureSnapshot: PhotoExposureSnapshot?", in: model)
        #expect(snapshot.contains("oldValue?.isoLocked != photoExposureSnapshot?.isoLocked"))
        #expect(snapshot.contains("oldValue?.shutterLocked != photoExposureSnapshot?.shutterLocked"))
        #expect(snapshot.contains("pushCameraHardwareControls()"))

        let usable = try body(after: "private var hasUsableExposureBiasRange: Bool", in: model)
        #expect(usable.contains("CameraHardwareControlPolicy.minimumRangeSpan"))
    }

    /// Source wiring only: Photo's busy flag must block adjustment writes without
    /// disabling the platform control inside a full-press callback. Native input
    /// delivery after a shot still requires a physical Camera Control test.
    @Test func photoCaptureBusyKeepsTheSliderPresentedButNotWritable() throws {
        let model = try source("App/Modules/CameraCapture/CameraViewModel.swift")

        let presented = try body(after: "private var areHardwareControlsPresented: Bool", in: model)
        #expect(!presented.contains("isPhotoCaptureBusy"),
                "the transient capture flag must not tear down the presented control")
        for stable in ["supportsCameraControl", "areHardwareControlsRequested", "cameraConfigured",
                       "lifecycleGate.isActive", "!isSwitchingCameraLens", "!isChangingFrameRate",
                       "!isChangingCaptureProfile", "!isStartingRecording", "!isStoppingRecording"] {
            #expect(presented.contains(stable),
                    "presentation keeps the stable gate \(stable)")
        }
        #expect(presented.contains("!isRecording && canAdjustEVThroughCurrentPath && hasUsableExposureBiasRange"),
                "the exposure policy moves with the stable half, unchanged")

        let eligible = try body(after: "private var areHardwareControlsEligible: Bool", in: model)
        #expect(eligible.contains("!isPhotoCaptureBusy && areHardwareControlsPresented"),
                "write acceptance is the stable half plus the one transient capture gate")
        #expect(!eligible.contains("guard supportsCameraControl"),
                "the split is one composition, not a second copy of the stable rules")

        // Only platform presentation follows the stable half...
        let push = try body(after: "private func pushCameraHardwareControls()", in: model)
        #expect(push.contains("isEnabled: areHardwareControlsPresented"))
        #expect(!push.contains("isEnabled: areHardwareControlsEligible"),
                "pushing the transient gate into the request is the dead-slider defect")

        // ...the value path still refuses a capture-time write and stale revision.
        let apply = try body(after: "private func applyCameraHardwareControlValue(", in: model)
        #expect(apply.contains("guard areHardwareControlsEligible,"))
        #expect(apply.contains("snapshot.cameraRevision == revision"))
    }

    /// Photo's busy flag is the still counterpart of Video's starting/recording
    /// window: the full press must stay armed across it instead of toggling the
    /// platform capture event off inside its own callback. The sheet/background,
    /// fault and disk gates still win.
    @Test func fullPressStaysArmedThroughPhotoBusyWithoutBypassingSafetyGates() throws {
        let content = try source("App/ContentView.swift")
        let enabled = try body(after: "private var hardwareCaptureEnabled: Bool", in: content)
        #expect(enabled.contains("guard cameraHardwareControlsVisible else { return false }"),
                "hidden, background, sheet and unsupported-device states still disarm")
        #expect(enabled.contains(
            "if cameraViewModel.isRecording || cameraViewModel.isStartingRecording { return true }"),
                "a take still receives its stop or startup cancel")
        #expect(enabled.contains("if cameraViewModel.isPhotoCaptureBusy { return true }"),
                "the transient photo window keeps the press armed")
        #expect(enabled.contains("return cameraViewModel.canChangeShootingMode"))
        #expect(enabled.contains("guard !showsRecordingFailure"))
        #expect(enabled.contains("cameraViewModel.errorMessage == nil"))
        #expect(enabled.contains("!cameraViewModel.isSpaceCritical"))

        // The transient branch is reached only after the fault and disk gates.
        let busyBranch = try #require(enabled.range(
            of: "if cameraViewModel.isPhotoCaptureBusy { return true }"))
        let faultGate = try #require(enabled.range(of: "guard !showsRecordingFailure"))
        let spaceGate = try #require(enabled.range(of: "isSpaceCritical"))
        #expect(faultGate.lowerBound < busyBranch.lowerBound,
                "a fault outranks the transient photo window")
        #expect(spaceGate.lowerBound < busyBranch.lowerBound,
                "critical storage outranks the transient photo window")
    }
}
