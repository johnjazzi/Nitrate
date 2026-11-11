import CoreGraphics
import Testing

struct PhotoZoomGeometryTests {
    @Test func oneXPreservesWholeExtent() throws {
        let extent = CGRect(x: 0, y: 0, width: 4032, height: 3024)
        #expect(try #require(PhotoZoomGeometry.centeredCrop(in: extent, zoom: 1)) == extent)
    }

    @Test func zoomCropIsCenteredAndNativeResolution() throws {
        let extent = CGRect(x: 0, y: 0, width: 4032, height: 3024)
        let crop = try #require(PhotoZoomGeometry.centeredCrop(in: extent, zoom: 2))
        #expect(crop == CGRect(x: 1008, y: 756, width: 2016, height: 1512))
        #expect(crop.width < extent.width && crop.height < extent.height)
    }

    @Test func handlesOrientedNonzeroOrigin() throws {
        #expect(try #require(PhotoZoomGeometry.centeredCrop(
            in: CGRect(x: 12, y: 24, width: 4000, height: 3000), zoom: 2
        )) == CGRect(x: 1012, y: 774, width: 2000, height: 1500))
    }

    @Test func rejectsUnsupportedAndNonfiniteZoom() {
        for zoom in [Double.nan, .infinity, -.infinity, 0.99, 4.01] {
            #expect(!PhotoZoomGeometry.isSupported(zoom))
            #expect(PhotoZoomGeometry.centeredCrop(in: CGRect(x: 0, y: 0, width: 16, height: 12), zoom: zoom) == nil)
        }
        #expect(PhotoZoomGeometry.isSupported(1))
        #expect(PhotoZoomGeometry.isSupported(4))
    }

    @Test func fourXProducesExactBoundedCenterCrop() throws {
        #expect(try #require(PhotoZoomGeometry.centeredCrop(
            in: CGRect(x: 0, y: 0, width: 4032, height: 3024), zoom: 4
        )) == CGRect(x: 1512, y: 1134, width: 1008, height: 756))
    }
}
