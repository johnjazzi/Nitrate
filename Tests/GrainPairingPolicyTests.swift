import Foundation
import Testing

/// The grain field's temporal cadence. `pairedAtHalfRate` shares one grain
/// realization per pair (30 Hz grain over 60 Hz motion) — the shared quantity is
/// the grain *index* (seed/z-slice/phase/coordinates), NOT a pixel-identical
/// composite. The two source frames differ in content.
struct GrainPairingPolicyTests {
    @Test func pairedAtHalfRateSharesOneIndexPerPair() {
        let indices = (0..<8).map { GrainPairingPolicy.grainIndex(frameIndex: UInt32($0), pairing: .pairedAtHalfRate) }
        #expect(indices == [0, 0, 1, 1, 2, 2, 3, 3])
    }

    @Test func perFrameIsIdentity() {
        let indices = (0..<8).map { GrainPairingPolicy.grainIndex(frameIndex: UInt32($0), pairing: .perFrame) }
        #expect(indices == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    @Test func pairingIsCodableRoundTrip() throws {
        for pairing in [GrainPairing.perFrame, .pairedAtHalfRate] {
            let data = try JSONEncoder().encode(pairing)
            #expect(try JSONDecoder().decode(GrainPairing.self, from: data) == pairing)
        }
        #expect(GrainPairing.perFrame.rawValue == "perFrame")
        #expect(GrainPairing.pairedAtHalfRate.rawValue == "pairedAtHalfRate")
    }
}
