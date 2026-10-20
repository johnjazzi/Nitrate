import Foundation
import Testing

/// The persisted per-job capture policy: a constrained value so an invalid
/// fps/shutter/grain combination cannot be constructed.
struct RenderCapturePolicyTests {
    @Test func twentyFourDerivesPerFrameAndFortyEight() throws {
        let policy = try #require(RenderCapturePolicy(24))
        #expect(policy.frameRate == 24)
        #expect(policy.grainPairing == .perFrame)
        #expect(policy.shutterDenominator == 48)
    }

    @Test func sixtyDerivesPairedHalfRateAndOneTwenty() throws {
        let policy = try #require(RenderCapturePolicy(60))
        #expect(policy.frameRate == 60)
        #expect(policy.grainPairing == .pairedAtHalfRate)
        #expect(policy.shutterDenominator == 120)
    }

    @Test func invalidFrameRateIsRejectedRatherThanCoerced() {
        #expect(RenderCapturePolicy(30) == nil)
        #expect(RenderCapturePolicy(0) == nil)
        #expect(RenderCapturePolicy(-24) == nil)
    }

    @Test func policyRoundTripsThroughJSON() throws {
        let source = try #require(RenderCapturePolicy(60))
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(RenderCapturePolicy.self, from: data) == source)
    }
}

/// A job carries the enqueue-time policy so a relaunch renders identically with
/// no live UI. Absent field is legacy: nil → 24 fps/perFrame/1/48.
struct RenderJobCapturePolicyTests {
    private func legacyJobJSON(_ job: RenderJob) throws -> Data {
        let encoded = try JSONEncoder().encode(job)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "capturePolicy")
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func legacyJobWithoutFieldDecodesNil() throws {
        let job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"), stockId: "s", iso: 400)
        let legacy = try legacyJobJSON(job)
        let decoded = try JSONDecoder().decode(RenderJob.self, from: legacy)
        #expect(decoded.capturePolicy == nil)
    }

    @Test func policySurvivesJobRoundTrip() throws {
        let job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/b.mov"), stockId: "s", iso: 400,
                            capturePolicy: RenderCapturePolicy(60))
        let decoded = try JSONDecoder().decode(RenderJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.capturePolicy == RenderCapturePolicy(60))
    }
}
