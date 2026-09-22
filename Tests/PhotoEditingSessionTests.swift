import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@main struct PhotoEditingSessionTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("FAIL: \(message)") }
    }
    static func main() {
        let first = PhotoEditRecipe(aperture: 1.4, sensorFocus: .init(x: 0.2, y: 0.3))
        let second = PhotoEditRecipe(aperture: 2.8, sensorFocus: .init(x: 0.8, y: 0.7))
        let last = PhotoEditRecipe(aperture: 16, sensorFocus: .init(x: 0.4, y: 0.6))
        var session = PhotoEditingSession(recipe: first)
        check(session.isSettled && session.beginNext() == nil, "initial image already rendered")
        session.select(second)
        let pending = session.beginNext()!
        check(session.beginNext() == nil, "at most one render in flight")
        session.select(first)
        session.select(last)
        check(!session.complete(pending, succeeded: true), "outdated image must never display")
        check(session.displayedRecipe == first, "old completion cannot overwrite visible recipe")
        let newest = session.beginNext()!
        check(newest.recipe == last, "intermediate requests coalesced")
        check(session.complete(newest, succeeded: true), "newest completion accepted")
        check(session.isSettled && session.displayedRecipe == last, "export may only use settled recipe")
        session.select(second)
        let failed = session.beginNext()!
        check(session.complete(failed, succeeded: false), "latest failure handled")
        check(session.desiredRecipe == last && session.isSettled, "failure restores last visible effect")
        session.select(first)
        let abandoned = session.beginNext()!
        session.invalidate()
        check(!session.complete(abandoned, succeeded: true) && session.beginNext() == nil, "dismissed editor rejects late completion")

        let bounds = CGSize(width: 400, height: 400)
        let photo = CGSize(width: 300, height: 600)
        check(PhotoEditGeometry.sensorPoint(at: CGPoint(x: 50, y: 200), viewSize: bounds, imageSize: photo, exif: 1) == nil, "letterbox tap is not an image tap")
        check(PhotoEditGeometry.sensorPoint(at: CGPoint(x: 150, y: 100), viewSize: bounds, imageSize: photo, exif: 1) == .init(x: 0.25, y: 0.25), "portrait aspect fit offset removed")
        let expected: [(Double, Double)] = [(0.2,0.3),(0.8,0.3),(0.8,0.7),(0.2,0.7),(0.3,0.2),(0.3,0.8),(0.7,0.8),(0.7,0.2)]
        for exif in 1...8 {
            let point = PhotoEditGeometry.sensorPoint(at: CGPoint(x: 80, y: 120), viewSize: bounds, imageSize: bounds, exif: UInt32(exif))!
            check(abs(point.x-expected[exif-1].0) < 0.0001 && abs(point.y-expected[exif-1].1) < 0.0001, "EXIF \(exif) inverse maps upright tap")
            let shown = PhotoEditGeometry.displayPoint(sensorPoint: point, viewSize: bounds, imageSize: bounds, exif: UInt32(exif))!
            check(abs(shown.x-80) < 0.001 && abs(shown.y-120) < 0.001, "EXIF \(exif) focus box matches tap")
        }
        check(PhotoEditGeometry.sensorPoint(at: .zero, viewSize: .zero, imageSize: photo, exif: 1) == nil, "zero layout rejected")
        check(PhotoEditGeometry.sensorPoint(at: CGPoint(x: Double.nan,y: 0), viewSize: bounds, imageSize: photo, exif: 1) == nil, "nonfinite point rejected")
        print("Photo editing session: \(checks) checks passed")
    }
}
