import Foundation
import Testing

struct FocalLengthRulerTests {
    @Test func majorTicksFireOnCrossingNotOnApproachOrStationaryEcho() {
        #expect(!FocalLengthRulerScale.crossesMajorTick(from: 25, to: 34))
        #expect(FocalLengthRulerScale.crossesMajorTick(from: 34, to: 35))
        #expect(!FocalLengthRulerScale.crossesMajorTick(from: 35, to: 35))
        #expect(!FocalLengthRulerScale.crossesMajorTick(from: 35, to: 36))
        #expect(FocalLengthRulerScale.crossesMajorTick(from: 36, to: 35))
        #expect(FocalLengthRulerScale.crossesMajorTick(from: 150, to: 13))
        #expect(!FocalLengthRulerScale.crossesMajorTick(from: .nan, to: 24))
    }

    @Test func rulerCentersCurrentFocalAndKeepsAdjacentLabelsSeparated() {
        #expect(FocalLengthRulerScale.offset(millimeters: 24, selected: 24) == 0)
        #expect(FocalLengthRulerScale.offset(millimeters: 13, selected: 24) < 0)
        #expect(FocalLengthRulerScale.offset(millimeters: 150, selected: 24) > 0)
        #expect(FocalLengthRulerScale.offset(millimeters: 110, selected: 96) >= 24)
    }
}
