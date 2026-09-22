import Foundation

@main
struct DepthMathTests {
    static var checks = 0
    static var failures = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if condition() { print("PASS: \(name)") }
        else { failures += 1; print("FAIL: \(name)") }
    }
    static func main() throws {
        let raster = try DepthRaster(width: 3, height: 2, values: [1, 2, 3, 4, 5, 6])
        let orientations: [[Float]] = [
            [1,2,3,4,5,6], [3,2,1,6,5,4], [6,5,4,3,2,1], [4,5,6,1,2,3],
            [1,4,2,5,3,6], [4,1,5,2,6,3], [6,3,5,2,4,1], [3,6,2,5,1,4]
        ]
        for exif in UInt32(1)...8 {
            let rotated = raster.oriented(exif: exif)
            expect(rotated.values == orientations[Int(exif)-1], "EXIF \(exif) pixel orientation")
            expect(rotated.width == (exif >= 5 ? 2 : 3), "EXIF \(exif) dimensions")
            let p = NormalizedImagePoint(x: 1.0/6.0, y: 0.25).oriented(exif: exif)
            expect(rotated.value(at: p) == 1, "EXIF \(exif) point and depth agree")
        }
        expect((try? DepthRaster(width: 0, height: 2, values: [])) == nil, "Reject empty map")
        expect((try? DepthRaster(width: 3, height: 2, values: [1])) == nil, "Reject incorrect buffer length")
        expect((try? DepthRaster(width: Int.max, height: 2, values: [])) == nil, "Reject size overflow")
        expect(!NormalizedImagePoint(x: .nan, y: 0).isValid, "Reject NaN tap")
        expect(!NormalizedImagePoint(x: 1.2, y: 0).isValid, "Reject out-of-image tap")

        // Synthetic three-depth scene: left near=2, middle focus=1, right far=0.25.
        let row = [Float](repeating: 2, count: 8) + [Float](repeating: 1, count: 8) + [Float](repeating: 0.25, count: 8)
        let scene = try DepthRaster(width: 24, height: 24, values: Array(repeating: row, count: 24).flatMap { $0 })
        let plan = try DepthMath.makePlan(depth: scene, focus: NormalizedImagePoint(x: 0.5, y: 0.5), isPerson: false, aperture: 1.4)
        expect(plan.near[12*24+3] > 0.9, "Closer object blurs")
        expect(plan.far[12*24+20] > 0.9, "Farther object blurs")
        expect(plan.near[12*24+12] == 0 && plan.far[12*24+12] == 0, "Focus plane stays clear")
        expect(plan.near[12*24+20] == 0 && plan.far[12*24+3] == 0, "Near and far are not reversed")
        expect(plan.nearFraction > 0.25 && plan.farFraction > 0.25, "Nonempty depth coverage")
        expect(plan.near.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "Finite normalized CoC")
        let smaller = try DepthMath.makePlan(depth: scene, focus: NormalizedImagePoint(x: 0.5, y: 0.5), isPerson: false, aperture: 16)
        expect(smaller.maxRadius(longEdge: 1600) < plan.maxRadius(longEdge: 1600) / 10, "f/16 much weaker than f/1.4")
        expect(abs(plan.maxRadius(longEdge: 3200) - 2*plan.maxRadius(longEdge: 1600)) < 0.001, "Radius scales with output resolution")
        var last = Float.infinity
        for f in DepthCapturePolicy.apertures {
            let r = DepthMath.radius(aperture: f, longEdge: 1600)
            expect(r < last && r >= 0, "Monotonic radius f/\(f)")
            last = r
        }
        expect(DepthMath.radius(aperture: .nan, longEdge: 1600).isFinite, "NaN aperture sanitised")
        let scaled = try DepthRaster(width: 24, height: 24, values: scene.values.map { $0 * 10 })
        let scaledPlan = try DepthMath.makePlan(depth: scaled, focus: NormalizedImagePoint(x: 0.5, y: 0.5), isPerson: false, aperture: 1.4)
        expect(zip(scaledPlan.far, plan.far).allSatisfy { abs($0-$1) < 0.0001 }, "Disparity scale does not change relative effect")

        // Relative disparity can have an unknown additive offset. The same scene and
        // tap must retain the same clear/near/far regions after an affine recalibration.
        // Five layers include partial blur amounts, so saturation cannot hide a change.
        let gradedRow = [Float](repeating: 1.8, count: 5) + [Float](repeating: 1.25, count: 5)
            + [Float](repeating: 1, count: 5) + [Float](repeating: 0.75, count: 5)
            + [Float](repeating: 0.4, count: 5)
        let graded = try DepthRaster(width: 25, height: 25,
                                     values: Array(repeating: gradedRow, count: 25).flatMap { $0 })
        let tap = NormalizedImagePoint(x: 0.5, y: 0.5)
        let gradedPlan = try DepthMath.makePlan(depth: graded, focus: tap, isPerson: false, aperture: 1.8)
        expect(gradedPlan.near[12*25+7] > 0 && gradedPlan.near[12*25+7] < 1,
               "Offset regression fixture includes partial foreground blur")
        expect(gradedPlan.far[12*25+17] > 0 && gradedPlan.far[12*25+17] < 1,
               "Offset regression fixture includes partial background blur")
        for (scale, offset): (Float, Float) in [(1, -0.2), (1, 0.4), (1, 10), (1, 1000), (3, 7)] {
            let recalibrated = try DepthRaster(width: 25, height: 25,
                                               values: graded.values.map { $0*scale+offset })
            let equivalent = try? DepthMath.makePlan(depth: recalibrated, focus: tap,
                                                     isPerson: false, aperture: 1.8)
            expect(equivalent != nil, "Valid relative scene survives scale \(scale), offset \(offset)")
            if let equivalent {
                expect(zip(equivalent.near, gradedPlan.near).allSatisfy { abs($0-$1) < 0.0002 },
                       "Foreground blur is invariant to scale \(scale), offset \(offset)")
                expect(zip(equivalent.far, gradedPlan.far).allSatisfy { abs($0-$1) < 0.0002 },
                       "Background blur is invariant to scale \(scale), offset \(offset)")
            }
        }

        // The tap is on a small object next to a different depth: four of the nine
        // samples match the tap, five belong to its neighbour. Offset must not merge
        // the two clusters and silently move focus to the majority/background plane.
        var boundary = graded.values
        for y in 11...13 { for x in 11...13 { boundary[y*25+x] = 0.7 } }
        for (x, y) in [(12, 12), (11, 12), (12, 11), (11, 11)] { boundary[y*25+x] = 1 }
        let edgeMap = try DepthRaster(width: 25, height: 25, values: boundary)
        let edgePlan = try DepthMath.makePlan(depth: edgeMap, focus: tap, isPerson: false, aperture: 1.8)
        let edgeOffset = try DepthRaster(width: 25, height: 25, values: boundary.map { $0+10 })
        let shiftedEdgePlan = try DepthMath.makePlan(depth: edgeOffset, focus: tap, isPerson: false, aperture: 1.8)
        expect(edgePlan.near[12*25+12] == 0 && edgePlan.far[12*25+12] == 0,
               "Boundary tap retains its own depth cluster")
        expect(zip(shiftedEdgePlan.near, edgePlan.near).allSatisfy { abs($0-$1) < 0.0002 }
               && zip(shiftedEdgePlan.far, edgePlan.far).allSatisfy { abs($0-$1) < 0.0002 },
               "Disparity offset does not move a boundary tap to its neighbour")

        // Removing dependence on the absolute disparity must not stretch sensor
        // noise into strong blur. This checker noise has no coherent depth regions.
        for offset: Float in [-0.998, 0, 20] {
            let noise = (0..<625).map { i -> Float in
                1 + ((i/25+i%25).isMultiple(of: 2) ? -0.001 : 0.001) + offset
            }
            let noisy = try DepthRaster(width: 25, height: 25, values: noise)
            expect((try? DepthMath.makePlan(depth: noisy, focus: tap, isPerson: false, aperture: 1.8)) == nil,
                   "Unstructured flat-scene noise is rejected with offset \(offset)")
        }

        // A smooth, nearly flat depth ramp has very little adjacent-pixel noise.
        // Its small span must not be stretched to maximum blur merely because it
        // is spatially coherent. Offsets cannot change this decision either.
        for span: Float in [0.001, 0.01, 0.02] {
            for offset: Float in [0, 10] {
                let ramp = (0..<(101*101)).map { i in 1+offset+span*Float(i%101)/100 }
                let flatRamp = try DepthRaster(width: 101, height: 101, values: ramp)
                expect((try? DepthMath.makePlan(depth: flatRamp, focus: tap, isPerson: false, aperture: 1.4)) == nil,
                       "Nearly flat smooth ramp span \(span), offset \(offset) is not forced to blur")
            }
        }
        for offset: Float in [0, 10] {
            let ramp = (0..<(101*101)).map { i in 1+offset+0.03*Float(i%101)/100 }
            let shallow = try DepthRaster(width: 101, height: 101, values: ramp)
            let shallowPlan = try DepthMath.makePlan(depth: shallow, focus: tap, isPerson: false, aperture: 1.4)
            expect(shallowPlan.blurAmount.max()! < 0.05,
                   "Just-separated smooth ramp keeps weak blur after offset \(offset)")
        }

        var disconnected = scene.values
        disconnected[12*24+20] = 1
        let samePlane = try DepthRaster(width: 24, height: 24, values: disconnected)
        let samePlan = try DepthMath.makePlan(depth: samePlane, focus: NormalizedImagePoint(x: 0.5, y: 0.5), isPerson: false, aperture: 1.4)
        expect(samePlan.far[12*24+20] == 0, "Disconnected object at same depth also stays sharp")
        let allFlat = try DepthRaster(width: 24, height: 24, values: [Float](repeating: 1, count: 576))
        expect((try? DepthMath.makePlan(depth: allFlat, focus: nil, isPerson: false, aperture: 1.4)) == nil, "Flat scene is not forced to blur")
        var outlier = allFlat.values; outlier[0] = 100000
        expect((try? DepthMath.makePlan(depth: DepthRaster(width: 24, height: 24, values: outlier), focus: nil, isPerson: false, aperture: 1.4)) == nil, "One outlier cannot stretch a flat scene")
        let empty = try DepthRaster(width: 24, height: 24, values: [Float](repeating: .nan, count: 576))
        expect((try? DepthMath.makePlan(depth: empty, focus: nil, isPerson: false, aperture: 1.4)) == nil, "Invalid depth never fakes success")
        var holes = scene.values
        for y in 0..<8 { for x in 0..<8 { holes[y*24+x] = .nan } }
        let holePlan = try DepthMath.makePlan(depth: DepthRaster(width: 24, height: 24, values: holes), focus: NormalizedImagePoint(x: 0.5, y: 0.5), isPerson: false, aperture: 1.4)
        expect(holePlan.near[2*24+2] == 0 && holePlan.far[2*24+2] == 0, "Unknown is not silently treated as background")
        expect((try? DepthMath.makePlan(depth: DepthRaster(width: 24, height: 24, values: holes), focus: NormalizedImagePoint(x: 0.05, y: 0.05), isPerson: false, aperture: 1.4)) == nil, "Invalid user-selected region is reported, not moved")
        let ref = [UInt8](repeating: 120, count: 100*4)
        let mask = [UInt8](repeating: 255, count: 100)
        let noChange = try EffectMeasurement(originalRGBA: ref, renderedRGBA: ref, mask: mask)
        expect(!noChange.hasVisibleChange, "Identical output is not marked visibly blurred")
        var changed = ref
        for i in stride(from: 0, to: changed.count, by: 4) { changed[i] = 160 }
        let actual = try EffectMeasurement(originalRGBA: ref, renderedRGBA: changed, mask: mask)
        expect(actual.hasVisibleChange, "Visible pixel change is detected")
        let noRegion = try EffectMeasurement(originalRGBA: ref, renderedRGBA: changed, mask: [UInt8](repeating: 0, count: 100))
        expect(!noRegion.hasVisibleChange, "No eligible region cannot count as successful blur")
        expect((try? EffectMeasurement(originalRGBA: ref, renderedRGBA: [], mask: mask)) == nil, "Mismatched measurement buffer rejected")
        print("\n\(checks) depth math checks; \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
