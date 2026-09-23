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
                transientDeviceFocus: point, captureSummary: "native-priority camera route fixture",
                prefersAppleDepth: preferApple, forceModelOnAppleFailure: true)
        }
        let noEstimation = EstimationProbe()
        let processor = DepthPhotoProcessor(depthEstimator: { try noEstimation.estimate($0) })
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
        expect(noEstimation.calls == 0, "successful Apple and explicit/native computational routes skip estimation")
        let rgb = try AppleDepthTestFixture.photo(context: context, includeDepth: false)
        let estimatedDepth = try DepthRaster(width: 96, height: 64,
            values: (0..<96*64).map { $0 % 96 < 48 ? 0.8 : 0.2 })
        let model = EstimationProbe(depth: estimatedDepth)
        let estimator = DepthPhotoProcessor(depthEstimator: { try model.estimate($0) })
        let noNative = try await estimator.process(capture(rgb, native: nil, preferApple: true))
        expect(noNative.renderer == .computational && noNative.outcome.canCompare && noNative.editDepthData != nil,
               "main without native depth preserves intelligent fallback, never claims Apple rendering")
        expect(noNative.diagnosticText.contains("appleFallbackReason="), "fallback has an explicit diagnostic reason")
        expect(model.calls == 1, "missing native depth estimates exactly once")
        // Reusing the valid snapshot after the container fails Apple rendering
        // must fail these provenance and estimation assertions.
        let incompatible = try await estimator.process(capture(rgb, native: native, preferApple: true))
        expect(incompatible.renderer == .computational && incompatible.outcome.canCompare && incompatible.editRecipe != nil,
               "native snapshot without native container cannot silently claim Apple success")
        expect(incompatible.diagnosticText.contains("appleFallbackReason="), "failed Apple attempt is recorded")
        expect(model.calls == 2, "failed Apple rendering estimates once even when a usable native snapshot exists")
        if let bytes = incompatible.editDepthData {
            let saved = try PhotoDepthData.decode(bytes)
            expect(saved.source == .estimated && saved.raster.values == estimatedDepth.values,
                   "Apple failure persists the actual model estimate instead of relabelling native depth")
        } else { expect(false, "Apple failure retains estimated depth for editing") }
        if let recipe = incompatible.editRecipe {
            let reopened = try await PhotoEditingRenderer().render(sourceData: rgb, recipe: recipe,
                depthData: incompatible.editDepthData)
            let difference = try pixelDifference(incompatible.jpegData, reopened.jpegData, context: context)
            expect(difference < 1, "estimated Apple fallback can reproduce its initial effect after reopening")
        }
        let unavailableModel = EstimationProbe()
        let failedModel = try await DepthPhotoProcessor(depthEstimator: { try unavailableModel.estimate($0) })
            .process(capture(rgb, native: native, preferApple: true))
        expect(unavailableModel.calls == 1, "Apple failure reaches the model even when the model throws")
        expect(failedModel.outcome == .renderFailed && failedModel.editRecipe == nil
               && failedModel.editDepthData == nil && !failedModel.jpegData.isEmpty,
               "failed model fallback keeps an ordinary photo without claiming an editable result")
        let explicitFailedApple = try await processor.process(capture(rgb, native: native, preferApple: true), renderer: .apple)
        expect(explicitFailedApple.renderer == .apple && explicitFailedApple.outcome == .renderFailed
               && explicitFailedApple.appleFallbackReason == nil && noEstimation.calls == 0,
               "explicit Apple comparison keeps its failed Apple result without model fallback")
        let importedCapture = CapturedPhoto(data: rgb, depthRequested: true, hasDepthData: true,
            nativeDepth: native, options: .init(enabled: true, aperture: 1.4),
            transientDeviceFocus: point, captureSummary: "existing import policy fixture", prefersAppleDepth: true)
        let imported = try await processor.process(importedCapture)
        expect(imported.outcome.canCompare && noEstimation.calls == 0,
               "existing import policy may reuse usable native depth after Apple failure")
        if let bytes = imported.editDepthData {
            let saved = try PhotoDepthData.decode(bytes)
            expect(saved.source == .native, "existing import policy preserves native fallback provenance")
        } else { expect(false, "existing import policy retains native fallback editing depth") }
        for snapshot in [nil, native] {
            let disabled = try await processor.process(capture(rgb, native: snapshot, preferApple: true, enabled: false))
            expect(disabled.outcome == .disabled && disabled.editRecipe == nil,
                   "depth-off remains ordinary capture with or without native depth")
        }
        expect(noEstimation.calls == 0, "depth-off never invokes the model")
        let flat = try AppleDepthTestFixture.photo(context: context, disparityValue: { _, _ in 0.5 })
        let flatSnapshot = NativeDepthSnapshot(raster: try DepthRaster(width: 768, height: 512,
            values: Array(repeating: 0.5, count: 768*512)), quality: "high", accuracy: "relative", filtered: true)
        let weak = try await processor.process(capture(flat, native: flatSnapshot, preferApple: true))
        expect(weak.renderer == .apple && weak.outcome == .weakEffect && weak.editRecipe != nil,
               "valid flat native depth remains an editable weak Apple effect")
        expect(weak.appleFallbackReason == nil && noEstimation.calls == 0,
               "weak Apple effect is not a failure and never invokes estimation")
        print("Main camera rendering: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }

    /// Only the expensive model is replaced; decoding, Apple rejection,
    /// computational rendering, and durable depth encoding remain real.
    private final class EstimationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let depth: DepthRaster?
        init(depth: DepthRaster? = nil) { self.depth = depth }
        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func estimate(_ image: CIImage) throws -> DepthRaster {
            lock.lock()
            count += 1
            lock.unlock()
            guard let depth else { throw Unavailable.model }
            return depth
        }
        private enum Unavailable: Error { case model }
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
