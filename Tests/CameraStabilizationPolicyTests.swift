import Testing

struct CameraStabilizationPolicyTests {
    @Test func missingConnectionOffersOnlyOff() {
        let capability = CameraStabilizationPolicy.Capability(connectionSupported: false,
                                                              formatModes: [.standard, .cinematic, .extreme])
        #expect(capability.availableModes == [.off])
        #expect(capability.effectiveMode(for: .extreme) == .off)
    }

    @Test func formatSupportIsRequired() {
        let capability = CameraStabilizationPolicy.Capability(connectionSupported: true, formatModes: [.standard])
        #expect(capability.availableModes == [.off, .standard])
        #expect(capability.effectiveMode(for: .cinematic) == .off)
        #expect(capability.effectiveMode(for: .standard) == .standard)
    }

    @Test func preferenceSurvivesUnsupportedLens() {
        let preferred = CameraStabilizationMode.extreme
        #expect(CameraStabilizationPolicy.Capability.unavailable.effectiveMode(for: preferred) == .off)
        let supported = CameraStabilizationPolicy.Capability(connectionSupported: true, formatModes: [.extreme])
        #expect(supported.effectiveMode(for: preferred) == .extreme)
        #expect(preferred == .extreme)
    }

    @Test func changesFreezeDuringRecordingAndPendingStart() {
        #expect(CameraStabilizationPolicy.canChange(recording: false, starting: false, finishing: false))
        #expect(!CameraStabilizationPolicy.canChange(recording: true, starting: false, finishing: false))
        #expect(!CameraStabilizationPolicy.canChange(recording: false, starting: true, finishing: false))
        #expect(!CameraStabilizationPolicy.canChange(recording: false, starting: false, finishing: true))
    }

    @Test func unknownActiveModeIsNotReportedAsOffOrEnabled() {
        #expect(CameraStabilizationMode(activeRawValue: 0) == .off)
        #expect(CameraStabilizationMode(activeRawValue: 3) == .extreme)
        #expect(CameraStabilizationMode(activeRawValue: -1) == nil)
        #expect(CameraStabilizationMode(activeRawValue: 999) == nil)
    }

    @Test func offReadbackRemainsPendingEvenWhenRequestedModeIsSupported() {
        let capability = CameraStabilizationPolicy.Capability(connectionSupported: true, formatModes: [.cinematic])
        let snapshot = CameraStabilizationSnapshot(preferred: .cinematic, capability: capability,
            activeRawValue: 0, cameraRevision: 1, changesAllowed: true)
        #expect(snapshot.statusText == "Requested Cinematic · Active Off (pending)")
    }

    @Test func unsupportedPreferenceReportsActualFallback() {
        let snapshot = CameraStabilizationSnapshot(preferred: .extreme, capability: .unavailable,
            activeRawValue: 0, cameraRevision: 1, changesAllowed: true)
        #expect(snapshot.statusText == "Requested Extreme · Active Off (unsupported)")
    }

    @Test func persistenceDefaultsToOff() {
        #expect(CameraStabilizationMode(persistedValue: nil) == .off)
        #expect(CameraStabilizationMode(persistedValue: "invalid") == .off)
        #expect(CameraStabilizationMode(persistedValue: "extreme") == .extreme)
    }

    @Test func fulfilledPreferenceStillReportsRequestAndReadback() {
        let capability = CameraStabilizationPolicy.Capability(connectionSupported: true, formatModes: [.standard])
        let snapshot = CameraStabilizationSnapshot(preferred: .standard, capability: capability,
            activeRawValue: 1, cameraRevision: 1, changesAllowed: true)
        #expect(snapshot.statusText == "Requested Standard · Active Standard")
    }
}
