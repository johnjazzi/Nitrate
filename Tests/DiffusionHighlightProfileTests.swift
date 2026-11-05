import Foundation
import CoreImage
import Metal
import Testing

/// REGRESSION PROBE: the lens diffusion node must answer an isolated highlight
/// with a SMOOTH radial scatter.
///
/// A diffuser scatters a fraction of the light on its way through the glass.
/// That spread function is smooth and radially monotonic: every ring of
/// increasing radius outside the source's own footprint carries strictly less
/// scattered light than the ring inside it, and it keeps falling. Nothing in
/// the physics can produce a flat disc with an edge on it.
///
/// The node's multi-scale ladder is where that broke. Every level of the ladder
/// runs the SAME small kernel, so a level only averages its own grid if that
/// kernel spans more than a texel of it. At the 35mm gauge the target sigma is
/// small, the plan spread it over three levels, each level's kernel came out at
/// ~0.25 texels — a nearest filter — and the composite was a weighted stack of
/// texel-sized boxes (the coarsest one at 4x down, weight 0.55) rather than a
/// Gaussian. A developed ProRAW showed that as flat-topped 40-120 px discs with
/// a visible edge around streetlights and speculars (radius-4 preset, 0.10
/// effective still amount), while the same scene at the 75mm gauge — diffusion
/// bypassed — was clean.
///
/// This test builds the case synthetically and measures the radial profile in
/// scene units, ring by ring, so the SHAPE — not the total energy — is what is
/// under test.
@Suite(.serialized)
struct DiffusionHighlightProfileTests {
    private final class BundleToken {}

    private static let width = 1536
    private static let height = 2048

    /// 40x scene white: a streetlight core or specular, far above the tone
    /// curve, which is the condition the artifact is reported on. Pixels are
    /// named in the READ-BACK's row order (row 0 = top); Core Image's own
    /// coordinates put the origin at the bottom left, so quads are placed on
    /// the mirrored row — see `ciCentre(for:)`.
    private static let hotPixel = (x: 768, y: 1400)
    private static let hotValue: CGFloat = 40
    /// A streetlight is an extended source, not a point: this one is 13 px
    /// across here (~34 px at a 4032-wide develop), which is what puts the
    /// ladder's footprint inside the source instead of around a single texel.
    private static let hotRadius = 12
    /// A second, dimmer point at 4x white. The spread is geometry, so the shape
    /// must not depend on how bright the highlight is.
    private static let dimPixel = (x: 500, y: 600)
    private static let dimValue: CGFloat = 4

    private static var linearSRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! }

    private static func centre(_ pixel: (x: Int, y: Int)) -> CGPoint {
        CGPoint(x: Double(pixel.x) + 0.5, y: Double(pixel.y) + 0.5)
    }

    private static func ciCentre(_ pixel: (x: Int, y: Int)) -> CGPoint {
        CGPoint(x: Double(pixel.x) + 0.5, y: Double(height - 1 - pixel.y) + 0.5)
    }

    /// One scene-linear pixel at `value` times white, in Core Image coordinates.
    /// `CIColor` clamps its components to 0...1, so the over-white value comes
    /// from a colour matrix on a unit quad rather than from the colour itself.
    private func hotPixels(value: CGFloat) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        return CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: bounds)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: value, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: value, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: value, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
    }

    /// A disc of `radius` px of `value` times white, plus a single-pixel point,
    /// on black, at full still resolution.
    private func syntheticFrame(hotValue: CGFloat = hotValue) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let black = CIImage(color: .black).cropped(to: bounds)

        // The streetlight core: a hard-edged CIRCLE, so every 1 px ring cuts
        // the same arc of the source and the profile has no square-corner step
        // of its own. A half-texel feather is the only softness it carries.
        let r = CGFloat(Self.hotRadius)
        guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: Self.ciCentre(Self.hotPixel).x, y: Self.ciCentre(Self.hotPixel).y),
            "inputRadius0": r - 0.5,
            "inputRadius1": r + 0.5,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear,
        ]), let circleMask = gradient.outputImage else {
            Issue.record("the synthetic disc mask could not be built")
            return black
        }
        let core = hotPixels(value: hotValue).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: black,
            kCIInputMaskImageKey: circleMask,
        ])

        // The dim point: one pixel, 4x white.
        let dimRect = CGRect(x: Self.dimPixel.x, y: Self.height - 1 - Self.dimPixel.y, width: 1, height: 1)
        let point = hotPixels(value: Self.dimValue).cropped(to: dimRect)

        return point.composited(over: core).composited(over: black)
    }

    /// The still diffusion path the app renders, at `gauge`.
    ///
    /// The stock carries no diffusion of its own, so the gauge's preset applies;
    /// the stock's `stillDiffusionScale` of 0.5 takes the authored amount to the
    /// share a develop actually mixes (0.20 -> 0.10 at 35mm). `.disabled` is the
    /// same stock and gauge with only the node off, so the difference between
    /// the two renders is the node itself.
    private func still(gauge: PrintGauge, includingDiffusion: Bool) throws -> StillFilmRenderResources {
        try StillFilmRenderResources(
            stockID: "kodak5219",
            gauge: gauge,
            seed: 1,
            bundle: Bundle(for: BundleToken.self),
            diffusion: includingDiffusion ? nil : .some(.disabled)
        )
    }

    /// Apple Log 2 frame -> the still spatial stage (halation + diffusion) ->
    /// scene-linear image. `StillFilmEffectsStage.applyHalation` is the exact
    /// call `DevelopmentPhotoRenderer.develop` makes, with the still diffusion
    /// settings; the stock LUT, glow and grain that follow it only obscure a
    /// shape measurement, so the probe stops here and measures the scene light
    /// the node produced.
    private func stillEffects(_ frame: CIImage, resources: StillFilmRenderResources) throws -> CIImage {
        try resources.halation(RAWToLog2Stage.apply(frame), sceneLiftStops: 1)
    }

    /// Mean scene-linear luminance at 1 px wide rings of increasing radius from
    /// `centre`. Ring 0 is the peak texel itself.
    private func radialProfile(
        of output: CIImage,
        resources: StillFilmRenderResources,
        centre: CGPoint,
        maxRadius: Int
    ) -> [Double] {
        var values = [Float](repeating: 0, count: Self.width * Self.height * 4)
        resources.context.render(
            output,
            toBitmap: &values,
            rowBytes: Self.width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
            format: .RGBAf,
            colorSpace: Self.linearSRGB
        )

        var sums = [Double](repeating: 0, count: maxRadius + 1)
        var counts = [Int](repeating: 0, count: maxRadius + 1)
        let cx = Int(centre.x), cy = Int(centre.y)
        for y in (cy - maxRadius)...(cy + maxRadius) where y >= 0 && y < Self.height {
            for x in (cx - maxRadius)...(cx + maxRadius) where x >= 0 && x < Self.width {
                let dx = Double(x) + 0.5 - centre.x
                let dy = Double(y) + 0.5 - centre.y
                let radius = Int((dx * dx + dy * dy).squareRoot())
                guard radius <= maxRadius else { continue }
                let index = (y * Self.width + x) * 4
                // Apple Log 2 code back to scene light. The source is neutral,
                // so the mean of the three channels is this probe's luminance.
                let scene = (0..<3).reduce(0.0) {
                    $0 + PhotoColorMath.appleLog2Decode(Double(values[index + $1]))
                } / 3
                sums[radius] += scene
                counts[radius] += 1
            }
        }
        return (0...maxRadius).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 0 }
    }

    private func describe(_ profile: [Double]) -> String {
        profile.enumerated()
            .map { String(format: "r%02d=%.5f", $0.offset, $0.element) }
            .joined(separator: " ")
    }

    /// The renders, the profiles, and the halo the node adds (diffused minus
    /// undiffused — halation is in both, so this isolates the diffuser).
    private func measure(gauge: PrintGauge, centre: CGPoint, maxRadius: Int,
                         hotValue: CGFloat = hotValue) throws
        -> (halo: [Double], baseline: [Double], effect: [Double]) {
        let frame = syntheticFrame(hotValue: hotValue)
        let lit = try still(gauge: gauge, includingDiffusion: true)
        let bare = try still(gauge: gauge, includingDiffusion: false)
        let halo = radialProfile(of: try stillEffects(frame, resources: lit),
                                 resources: lit, centre: centre, maxRadius: maxRadius)
        let baseline = radialProfile(of: try stillEffects(frame, resources: bare),
                                     resources: bare, centre: centre, maxRadius: maxRadius)
        let effect = zip(halo, baseline).map { max(0, $0 - $1) }
        return (halo, baseline, effect)
    }

    /// THE property the artifact violates: outside the source's own footprint
    /// the scatter must keep falling, ring by ring — no plateau, no ripple, no
    /// secondary bump, no hard step.
    @Test func diffusionScatterIsSmoothAndMonotonicAroundAHighlight() throws {
        // 35mm is the reported gauge: the radius-4 preset at the 0.10 still
        // amount. The rings start outside the 6 px core, where light can only
        // come from the diffuser.
        let first = Self.hotRadius + 2
        let maxRadius = 40
        let hot = try measure(gauge: .thirtyFiveMillimetre, centre: Self.centre(Self.hotPixel),
                              maxRadius: maxRadius)
        print("DIFFUSION HALO   (35mm, 40x disc): \(describe(hot.halo))")
        print("NO-DIFFUSION     (35mm, 40x disc): \(describe(hot.baseline))")
        print("DIFFUSION EFFECT (35mm, 40x disc): \(describe(hot.effect))")

        #expect(hot.baseline[0] > Self.hotValue * 0.9, "the synthetic highlight did not render")
        #expect(hot.effect[first] > 0.01, "the diffuser added no light outside the core")

        assertSmoothDecay(hot.effect, from: first,
                          sigma: try deliveredSigma(gauge: .thirtyFiveMillimetre),
                          label: "35mm scatter")

        // The same core at 4x instead of 40x rides the same curve once its
        // own amplitude is normalised out: the scatter is geometry, not
        // brightness, so the shape cannot depend on how hot the highlight was.
        let dim = try measure(gauge: .thirtyFiveMillimetre, centre: Self.centre(Self.hotPixel),
                              maxRadius: maxRadius, hotValue: Self.dimValue)
        print("DIFFUSION EFFECT (35mm, 4x disc):  \(describe(dim.effect))")
        let hotNormalised = hot.effect.map { $0 / max(hot.effect[first], 0.0001) }
        let dimNormalised = dim.effect.map { $0 / max(dim.effect[first], 0.0001) }
        for radius in first...min(maxRadius, first + 3) {
            #expect(abs(hotNormalised[radius] - dimNormalised[radius]) < 0.03,
                    "scatter must not depend on brightness: r\(radius) 40x \(hotNormalised[radius]) 4x \(dimNormalised[radius])")
        }
    }

    /// The same shape at the 16mm gauge, where the ladder really does run more
    /// than one level (2 at this width): the fix is the ladder's depth, so the
    /// remaining pyramid has to keep the property too.
    @Test func ladderedScatterIsSmoothAtTheSixteenMillimetreGauge() throws {
        let first = Self.hotRadius + 2
        let measured = try measure(gauge: .sixteenMillimetre, centre: Self.centre(Self.hotPixel),
                                   maxRadius: 48)
        print("DIFFUSION EFFECT (16mm, 40x disc): \(describe(measured.effect))")
        #expect(measured.effect[first] > 0.01, "the diffuser added no light outside the core")
        assertSmoothDecay(measured.effect, from: first,
                          sigma: try deliveredSigma(gauge: .sixteenMillimetre),
                          label: "16mm scatter")
    }

    /// The blur the node delivers at this width, in FULL-resolution pixels: the
    /// plan's aggregate sigma on the half-resolution working buffer, doubled
    /// back to source pixels. This is the radius the preset claims, so it is
    /// the yardstick the measured scatter has to live up to.
    private func deliveredSigma(gauge: PrintGauge) throws -> Double {
        let resources = try still(gauge: gauge, includingDiffusion: true)
        let plan = try #require(resources.config.effectiveStillDiffusion
            .plan(sourceWidth: Self.width))
        return Double(plan.realizedSigmaLevelZero) * 2
    }

    /// Outside `from`, every ring is below the one inside it, the fall never
    /// stalls while there is still light to lose, and — the property the
    /// artifact broke — the scatter does not reach further than the lens is
    /// authored to reach. A ladder level that cannot afford a real kernel hands
    /// back its texel grid, and that grid's footprint shows up here as a wide,
    /// almost flat skirt ending in a visible edge.
    private func assertSmoothDecay(_ profile: [Double], from: Int, sigma: Double, label: String) {
        // Only where the scatter is above the frame's own floor.
        let peak = profile[from...].max() ?? 0
        let limit = min(profile.count - 2,
                        profile.lastIndex { $0 > peak * 0.005 } ?? profile.count - 2)
        #expect(limit >= from + 2, "\(label): the scatter does not extend beyond the core")

        // 10% of the peak: the visible edge of a halo.
        let reach = Double(profile.lastIndex { $0 > peak * 0.1 } ?? from)
        #expect(reach >= Double(from) + 1, "\(label): the node barely spread any light")
        #expect(reach <= Double(from) + 3 * sigma,
                "\(label): scatter reaches r\(reach) for a \(sigma) px sigma — a \(reach - Double(from)) px skirt instead of the authored radius")

        for radius in (from + 1)...max(from + 1, limit) {
            let previous = profile[radius - 1]
            // A 1.5% allowance absorbs float rounding in a falling tail.
            #expect(profile[radius] <= previous * 1.015 + peak * 1e-6,
                    "\(label): r\(radius) = \(profile[radius]) rises above r\(radius - 1) = \(previous)")
            // No plateau: while the scatter still carries light, the fall must
            // not stall from one ring to the next.
            if previous > peak * 0.05 {
                #expect(profile[radius] < previous * 0.97,
                        "\(label): scatter is flat from r\(radius - 1) to r\(radius): \(previous) -> \(profile[radius])")
            }
        }
    }
}
