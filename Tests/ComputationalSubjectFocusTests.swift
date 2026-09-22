// The fixture intentionally gives one selected person a moderate depth spread.
// Expanding the whole scene, using a full-person cutout, trusting mask fringe
// samples, or reusing the selection after refocus each breaks a separate check.
import Foundation

@main struct ComputationalSubjectFocusTests {
    static var checks = 0
    static var failures = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if condition() { print("PASS: \(name)") }
        else { failures += 1; print("FAIL: \(name)") }
    }
    static func main() throws {
        let fixture = try scene()
        let tap = NormalizedImagePoint(x: 0.5, y: 0.55)
        let plan = try adaptivePlan(depth: fixture.depth, focus: tap, confidence: fixture.confidence)
        expect(plan.blurAmount[30*100+50] < 0.02,
               "Selecting the sleeve preserves detail in the same person's core head plane")
        expect(plan.blurAmount[55*100+50] == 0 && plan.blurAmount[78*100+50] < 0.02,
               "The selected sleeve and core torso remain clear")
        expect(plan.far[50*100+20] > 0.18,
               "The same person's substantially farther arm still receives depth blur")
        expect(plan.near[62*100+35] > 0.8,
               "Sparse extreme subject depths cannot become a full-person cutout")
        expect(plan.far[10*100+50] > 0.9,
               "Subject adaptation preserves strong distant background blur at f1.4")
        expect(plan.far[30*100+80] > 0.7,
               "A different person outside the selected instance remains out of focus")
        expect(abs(plan.maxRadius(longEdge: 4032)-80.64) < 0.01,
               "Subject detail is not recovered by reducing the whole-image f1.4 radius")
        let backgroundFocus = NormalizedImagePoint(x: 0.5, y: 0.1)
        let refocused = try adaptivePlan(depth: fixture.depth, focus: backgroundFocus, confidence: fixture.confidence)
        expect(refocused.near[30*100+50] > 0.9 && refocused.near[55*100+50] > 0.9,
               "Refocusing the background disables a stale subject selection and blurs the person")
        expect(refocused.blurAmount[10*100+50] == 0,
               "The chosen background stays at the original focus plane")
        var fringe = fixture.confidence
        for i in fringe.indices where fringe[i] == 0 { fringe[i] = 0.4 }
        let fringePlan = try adaptivePlan(depth: fixture.depth, focus: tap, confidence: fringe)
        expect(fringePlan.blurAmount[30*100+50] < 0.02 && fringePlan.far[30*100+80] > 0.7
               && fringePlan.far[10*100+50] > 0.9,
               "Low-confidence mask fringe neither widens the subject range nor protects background")
        var uncertainTap = fixture.confidence
        uncertainTap[55*100+50] = 0.4
        let uncertain = try adaptivePlan(depth: fixture.depth, focus: tap, confidence: uncertainTap)
        expect(uncertain.far[30*100+50] > 0.7,
               "A low-confidence tap cannot activate same-person focus expansion")
        let outlierFocus = NormalizedImagePoint(x: 0.35, y: 0.62)
        let outlierPlan = try adaptivePlan(depth: fixture.depth, focus: outlierFocus, confidence: fixture.confidence)
        expect(outlierPlan.far[30*100+50] > 0.9 && outlierPlan.far[55*100+50] > 0.9,
               "Tapping an extreme subject depth does not pull the core body into focus")
        for (scale, offset): (Float, Float) in [(1, 10), (3, 7)] {
            let shifted = try DepthRaster(width: 100, height: 100, values: fixture.depth.values.map { $0*scale+offset })
            let shiftedPlan = try adaptivePlan(depth: shifted, focus: tap, confidence: fixture.confidence)
            expect(zip(plan.near, shiftedPlan.near).allSatisfy { abs($0-$1) < 0.0002 }
                   && zip(plan.far, shiftedPlan.far).allSatisfy { abs($0-$1) < 0.0002 },
                   "Subject adaptation preserves native/estimated relative disparity scale and offset")
        }
        var smallHeadValues = [Float](repeating: 0.03, count: 10000)
        var smallHeadMask = [Float](repeating: 0, count: 10000)
        for y in 10..<90 { for x in 30..<70 {
            smallHeadValues[y*100+x] = y < 16 ? 0.34 : 0.54
            smallHeadMask[y*100+x] = 1
        } }
        for y in 70..<95 { for x in 0..<10 { smallHeadValues[y*100+x] = 0.9 } }
        let smallHead = try DepthRaster(width: 100, height: 100, values: smallHeadValues)
        let face = NormalizedImagePoint(x: 0.5, y: 0.13)
        let withFace = try adaptivePlan(depth: smallHead, focus: tap, confidence: smallHeadMask, face: face)
        expect(withFace.blurAmount[13*100+50] < 0.02,
               "A reliable face occupying 7.5% of the person is not discarded as a depth outlier")
        let faceTap = try adaptivePlan(depth: smallHead, focus: face, confidence: smallHeadMask, face: face)
        expect(faceTap.blurAmount[55*100+50] < 0.02,
               "Tapping a small reliable face keeps the nearby core body in focus")
        for invalidFace in [NormalizedImagePoint(x: 0.85, y: 0.3), .init(x: -0.1, y: 0.13)] {
            let rejected = try adaptivePlan(depth: smallHead, focus: tap, confidence: smallHeadMask, face: invalidFace)
            expect(rejected.far[13*100+50] > 0.7,
                   "A face outside the selected instance/image cannot expand its clear range")
        }
        var uncertainFaceMask = smallHeadMask
        uncertainFaceMask[13*100+50] = 0.7
        let uncertainFace = try adaptivePlan(depth: smallHead, focus: tap, confidence: uncertainFaceMask, face: face)
        expect(uncertainFace.far[13*100+49] > 0.7,
               "A low-confidence face anchor cannot override robust body depth")
        var missingFaceValues = smallHeadValues
        missingFaceValues[13*100+50] = 0
        let missingFaceDepth = try DepthRaster(width: 100, height: 100, values: missingFaceValues)
        let missingFace = try adaptivePlan(depth: missingFaceDepth, focus: tap, confidence: smallHeadMask, face: face)
        expect(missingFace.far[13*100+49] > 0.7,
               "A face anchor on unknown depth cannot borrow its neighbour's plane")
        var distantFaceValues = smallHeadValues
        for y in 10..<16 { for x in 30..<70 { distantFaceValues[y*100+x] = 0.15 } }
        let distantFaceDepth = try DepthRaster(width: 100, height: 100, values: distantFaceValues)
        let distantFace = try adaptivePlan(depth: distantFaceDepth, focus: tap, confidence: smallHeadMask, face: face)
        expect(distantFace.far[13*100+50] > 0.9,
               "A face farther than the scene-scaled adaptation bound remains out of focus")
        let armFocus = NormalizedImagePoint(x: 0.2, y: 0.5)
        let armTap = try adaptivePlan(depth: fixture.depth, focus: armFocus, confidence: fixture.confidence,
                                      face: NormalizedImagePoint(x: 0.5, y: 0.3))
        expect(armTap.near[55*100+50] > 0.9,
               "A valid face anchor does not override a tap on an outlying extended arm")
        print("Computational subject focus: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
    static func adaptivePlan(depth: DepthRaster, focus: NormalizedImagePoint, confidence: [Float],
                             face: NormalizedImagePoint? = nil) throws -> DepthPlan {
        try DepthMath.makePlan(depth: depth, focus: focus, isPerson: false, aperture: 1.4,
                               selectedSubjectConfidence: confidence, selectedSubjectFace: face)
    }
    static func scene() throws -> (depth: DepthRaster, confidence: [Float]) {
        var values = [Float](repeating: 0.03, count: 10000)
        var mask = [Float](repeating: 0, count: 10000)
        for y in 20..<85 { for x in 30..<70 {
            values[y*100+x] = y < 40 ? 0.34 : (y < 70 ? 0.54 : 0.58)
            mask[y*100+x] = 1
        } }
        for y in 45..<58 { for x in 12..<30 { values[y*100+x] = 0.25; mask[y*100+x] = 1 } }
        for y in 60..<64 { for x in 34..<38 { values[y*100+x] = 0.95 } }
        for y in 20..<50 { for x in 75..<90 { values[y*100+x] = 0.34 } }
        for y in 70..<95 { for x in 0..<10 { values[y*100+x] = 0.9 } }
        return (try DepthRaster(width: 100, height: 100, values: values), mask)
    }
}
