import Foundation
import CoreImage
import ImageIO
import AVFoundation

@main
struct MainCameraRenderingTests {
    static var checks = 0
    static var failures = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }
    static func main() async throws {
        let context = CIContext()
        let data = try AppleDepthTestFixture.photo(context: context)
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil)!
        let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeDisparity)!
        let native = try NativeDepthSnapshot(depthData: AVDepthData(fromDictionaryRepresentation: auxiliary as! [AnyHashable: Any]))
        let point = NormalizedImagePoint(x: 0.22, y: 0.27)
        func capture(_ data: Data, native: NativeDepthSnapshot?, preferApple: Bool, enabled: Bool = true) -> CapturedPhoto {
            CapturedPhoto(data: data, depthRequested: native != nil, hasDepthData: native != nil,
                nativeDepth: native, options: .init(enabled: enabled, aperture: 1.4),
                transientDeviceFocus: point, captureSummary: "main-camera route fixture", prefersAppleDepth: preferApple)
        }
        enum UnexpectedEstimation: Error { case attempted }
        let processor = DepthPhotoProcessor(depthEstimator: { _ in throw UnexpectedEstimation.attempted })
        let main = try await processor.process(capture(data, native: native, preferApple: true))
        expect(main.renderer == .apple && main.outcome.canCompare, "main with native depth calls Apple renderer")
        expect(main.editRecipe != nil && main.editDepthData == nil,
               "main keeps native source container and Apple editor route, not a computational sidecar")
        let explicitApple = try await processor.process(capture(data, native: native, preferApple: false), renderer: .apple)
        let originalDifference = try pixelDifference(main.jpegData, explicitApple.jpegData, context: context)
        expect(originalDifference < 1,
               "automatic main reproduces explicit original Apple API output")
        if let recipe = main.editRecipe {
            let reopened = try await PhotoEditingRenderer().render(sourceData: data, recipe: recipe,
                depthData: main.editDepthData)
            let reopenedDifference = try pixelDifference(main.jpegData, reopened.jpegData, context: context)
            expect(reopenedDifference < 1,
                   "main reopening/editing retains the same Apple rendering")
        }
        let other = try await processor.process(capture(data, native: native, preferApple: false))
        expect(other.renderer == .computational && other.editDepthData != nil,
               "non-main lens retains existing computational route")
        let forced = try await processor.process(capture(data, native: native, preferApple: true), renderer: .computational)
        expect(forced.renderer == .computational && forced.editDepthData != nil,
               "explicit comparison renderer remains respected")
        let rgb = try AppleDepthTestFixture.photo(context: context, includeDepth: false)
        let estimator = DepthPhotoProcessor(depthEstimator: { _ in native.raster })
        let noNative = try await estimator.process(capture(rgb, native: nil, preferApple: true))
        expect(noNative.renderer == .computational && noNative.outcome.canCompare && noNative.editDepthData != nil,
               "main without native depth preserves intelligent fallback, never claims Apple rendering")
        expect(noNative.diagnosticText.contains("appleFallbackReason="), "fallback has an explicit diagnostic reason")
        let incompatible = try await processor.process(capture(rgb, native: native, preferApple: true))
        expect(incompatible.renderer == .computational && incompatible.outcome.canCompare,
               "native snapshot without native container cannot silently claim Apple success")
        expect(incompatible.diagnosticText.contains("appleFallbackReason="), "failed Apple attempt is recorded")
        let disabled = try await processor.process(capture(rgb, native: nil, preferApple: true, enabled: false))
        expect(disabled.outcome == .disabled && disabled.editRecipe == nil, "main depth-off remains ordinary capture")
        print("Main camera rendering: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
    static func pixelDifference(_ a: Data, _ b: Data, context: CIContext) throws -> Double {
        func pixels(_ data: Data) throws -> [UInt8] {
            guard let image = CIImage(data: data) else { throw CameraError.captureFailed }
            let w = Int(image.extent.width), h = Int(image.extent.height)
            var bytes = [UInt8](repeating: 0, count: w*h*4)
            bytes.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: w*4, bounds: image.extent,
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return bytes
        }
        let first = try pixels(a), second = try pixels(b)
        guard first.count == second.count else { return .infinity }
        return zip(first,second).reduce(0) { $0 + abs(Double($1.0)-Double($1.1)) } / Double(first.count)
    }
}
