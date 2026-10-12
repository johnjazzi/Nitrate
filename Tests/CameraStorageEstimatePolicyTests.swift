import Testing

struct CameraStorageEstimatePolicyTests {
    @Test func reservesCriticalSpaceAndAccountsForTwoRetainedCopies() {
        let seconds = CameraStorageEstimatePolicy.remainingSeconds(
            freeBytes: 2_000_000_000,
            criticalReserveBytes: 500_000_000,
            videoBitRate: 4_000_000,
            audioBitRate: 2_000_000
        )

        #expect(seconds == 1_000)
    }

    @Test func budgetDoesNotGoBelowZeroAfterReserve() {
        let seconds = CameraStorageEstimatePolicy.remainingSeconds(
            freeBytes: 400_000_000,
            criticalReserveBytes: 500_000_000,
            videoBitRate: 4_000_000,
            audioBitRate: 192_000
        )

        #expect(seconds == 0)
    }

    @Test func rejectsInvalidInputsAndChangesWithConfiguredBitrate() {
        #expect(CameraStorageEstimatePolicy.remainingSeconds(
            freeBytes: 2_000_000_000,
            criticalReserveBytes: 500_000_000,
            videoBitRate: 0,
            audioBitRate: 192_000
        ) == nil)
        #expect(CameraStorageEstimatePolicy.remainingSeconds(
            freeBytes: 2_000_000_000,
            criticalReserveBytes: 500_000_000,
            videoBitRate: 4_000_000,
            audioBitRate: -1
        ) == nil)

        let lowerRate = CameraStorageEstimatePolicy.remainingSeconds(
            freeBytes: 2_000_000_000,
            criticalReserveBytes: 500_000_000,
            videoBitRate: 4_000_000,
            audioBitRate: 192_000
        )
        let higherRate = CameraStorageEstimatePolicy.remainingSeconds(
            freeBytes: 2_000_000_000,
            criticalReserveBytes: 500_000_000,
            videoBitRate: 8_000_000,
            audioBitRate: 192_000
        )

        guard let lowerRate, let higherRate else {
            Issue.record("Valid bitrate inputs should produce an estimate")
            return
        }
        #expect(higherRate < lowerRate)
    }
}
