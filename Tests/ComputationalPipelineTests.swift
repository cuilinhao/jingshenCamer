import Foundation
import CoreImage
import ImageIO

@main
struct ComputationalPipelineTests {
    static var checks = 0
    static var failures = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures += 1; print("FAIL: \(message)") }
    }
    static func main() async throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let rawDepth = try DepthRaster(width: 96, height: 64,
            values: (0..<96*64).map { $0 % 96 < 48 ? 0.9 : 0.1 })
        let initialPoint = NormalizedImagePoint(x: 0.22, y: 0.27)
        let editor = PhotoEditingRenderer()
        for exif: UInt32 in 1...8 {
            let data = try AppleDepthTestFixture.photo(context: context, orientation: exif, includeDepth: false)
            let uprightDepth = rawDepth.oriented(exif: exif)
            let processor = DepthPhotoProcessor(depthEstimator: { _ in uprightDepth })
            let capture = CapturedPhoto(data: data, depthRequested: false, hasDepthData: false,
                nativeDepth: nil, options: .init(enabled: true, aperture: 1.4),
                transientDeviceFocus: initialPoint, captureSummary: "RGB-only physical lens")
            let result = try await processor.process(capture)
            expect(result.renderer == .computational && result.outcome == .applied,
                   "EXIF \(exif): RGB-only lens generates computational depth")
            guard let attachment = result.editDepthData, let recipe = result.editRecipe else {
                expect(false, "EXIF \(exif): successful capture retains edit depth and recipe"); continue
            }
            let saved = try PhotoDepthData.decode(attachment)
            expect(saved.source == .estimated && saved.raster.width == rawDepth.width
                   && saved.raster.height == rawDepth.height && saved.raster.values == rawDepth.values,
                   "EXIF \(exif): persisted depth returns to exact sensor orientation")
            expect(recipe.sensorFocus == initialPoint, "EXIF \(exif): focus remains in sensor coordinates")
            let edited = try await editor.render(sourceData: data, recipe: recipe, depthData: attachment)
            expect(edited.pixelWidth == result.pixelWidth && edited.pixelHeight == result.pixelHeight,
                   "EXIF \(exif): editing preserves upright full image size")
            let a = try pixels(result.jpegData, context: context), b = try pixels(edited.jpegData, context: context)
            let mean = zip(a,b).reduce(0.0) { $0 + abs(Double($1.0)-Double($1.1)) } / Double(a.count)
            expect(a.count == b.count && mean < 1, "EXIF \(exif): cached depth reproduces initial pixels (\(mean))")
            let encoded = CGImageSourceCreateWithData(edited.jpegData as CFData, nil)!
            expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(encoded, 0, kCGImageAuxiliaryDataTypeDisparity) == nil,
                   "EXIF \(exif): flattened export has no fabricated native depth")
            let far = try await editor.render(sourceData: data,
                recipe: .init(aperture: 1.4, sensorFocus: .init(x: 0.72, y: 0.27)), depthData: attachment)
            expect(far.jpegData != edited.jpegData, "EXIF \(exif): saved depth supports refocusing")
        }
        let data = try AppleDepthTestFixture.photo(context: context, includeDepth: false)
        func capture(enabled: Bool = true, native: NativeDepthSnapshot? = nil) -> CapturedPhoto {
            CapturedPhoto(data: data, depthRequested: native != nil, hasDepthData: native != nil,
                nativeDepth: native, options: .init(enabled: enabled, aperture: 1.4),
                transientDeviceFocus: initialPoint, captureSummary: "source policy fixture")
        }
        enum MustNotInfer: Error { case called }
        let failing = DepthPhotoProcessor(depthEstimator: { _ in throw MustNotInfer.called })
        let disabled = try await failing.process(capture(enabled: false))
        expect(disabled.outcome == .disabled && disabled.editDepthData == nil, "switch off bypasses inference")
        let native = NativeDepthSnapshot(raster: rawDepth, quality: "high", accuracy: "relative", filtered: true)
        let preferred = try await failing.process(capture(native: native))
        expect(preferred.outcome == .applied, "valid native depth works even if inference throws")
        if let attachment = preferred.editDepthData {
            let decoded = try PhotoDepthData.decode(attachment)
            expect(decoded.source == .native, "native provenance is preserved")
        } else { expect(false, "native depth is persisted for editing") }
        let failed = try await failing.process(capture())
        expect(failed.outcome == .renderFailed && failed.editRecipe == nil && !failed.jpegData.isEmpty,
               "inference error retains ordinary image without advertising editing")
        let invalid = NativeDepthSnapshot(raster: try .init(width: 96, height: 64,
            values: Array(repeating: 0, count: 96*64)), quality: "low", accuracy: "relative", filtered: false)
        let fallback = try await DepthPhotoProcessor(depthEstimator: { _ in rawDepth }).process(capture(native: invalid))
        expect(fallback.outcome == .applied && fallback.editDepthData != nil, "invalid native depth falls back to estimation")
        for preserveCenter in [false, true] {
            var values = rawDepth.values
            let cx = Int(initialPoint.x * 96), cy = Int(initialPoint.y * 64)
            for y in (cy-2)...(cy+2) { for x in (cx-2)...(cx+2) { values[y*96+x] = 0 } }
            if preserveCenter { values[cy*96+cx] = 0.9 }
            let hole = try DepthRaster(width: 96, height: 64, values: values)
            let snapshot = NativeDepthSnapshot(raster: hole, quality: "high", accuracy: "relative", filtered: true)
            let recovered = try await DepthPhotoProcessor(depthEstimator: { _ in rawDepth }).process(capture(native: snapshot))
            expect(recovered.outcome == .applied && recovered.editDepthData != nil,
                   "native focus \(preserveCenter ? "neighborhood" : "hole") tries estimator before giving up")
            if let bytes = recovered.editDepthData {
                let decoded = try PhotoDepthData.decode(bytes)
                expect(decoded.source == .estimated, "focus recovery records estimated provenance")
            }
            let bytes = try PhotoDepthData(raster: hole, source: .native).encoded()
            do {
                _ = try await editor.render(sourceData: data,
                    recipe: .init(aperture: 1.4, sensorFocus: initialPoint), depthData: bytes)
                expect(false, "existing cached focus hole must fail instead of silently rerunning estimation")
            } catch { expect(true, "editor preserves immutable depth and rejects a hole") }
        }
        let flat = try DepthRaster(width: 96, height: 64, values: Array(repeating: 0.5, count: 96*64))
        let flatResult = try await DepthPhotoProcessor(depthEstimator: { _ in flat }).process(capture())
        expect(flatResult.outcome == .weakEffect && flatResult.editDepthData != nil,
               "flat scene keeps editable depth without inventing blur")
        if CommandLine.arguments.contains("--model-smoke") {
            // Exercise the same lazy bundled-model path used by the camera UI,
            // rather than only trusting an injected numeric fixture.
            let actual = try await DepthPhotoProcessor().process(capture())
            expect(actual.outcome.canCompare && actual.editRecipe != nil && actual.editDepthData != nil,
                   "actual bundled model runs through RGB-only capture into editable output")
            if let bytes = actual.editDepthData, let recipe = actual.editRecipe {
                let decoded = try PhotoDepthData.decode(bytes)
                expect(decoded.source == .estimated, "actual model attachment identifies estimation")
                let reopened = try await editor.render(sourceData: data, recipe: recipe, depthData: bytes)
                expect(reopened.pixelWidth == actual.pixelWidth && reopened.pixelHeight == actual.pixelHeight,
                       "actual model depth can reopen without inference")
            }
        }
        print("Computational pipeline: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }

    static func pixels(_ data: Data, context: CIContext) throws -> [UInt8] {
        guard let image = CIImage(data: data) else { throw CameraError.captureFailed }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var result = [UInt8](repeating: 0, count: w*h*4)
        result.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: w*4, bounds: image.extent,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return result
    }
}
