import Foundation
import CoreImage
import CoreVideo

@main
struct MonocularDepthEstimatorTests {
    static var checks = 0
    static var failures = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); expect(false, message) }
        catch { expect(true, message) }
    }

    // Padded Core Video rows catch reading the width as the row stride.
    static func buffer(_ values: [Float], width: Int, height: Int,
                       format: OSType = kCVPixelFormatType_OneComponent16Half) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &result)
        guard status == kCVReturnSuccess, let result else { throw TestError.buffer }
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let address = CVPixelBufferGetBaseAddress(result)!
        for y in 0..<height {
            let row = address.advanced(by: y * CVPixelBufferGetBytesPerRow(result))
            for x in 0..<width {
                if format == kCVPixelFormatType_OneComponent16Half {
                    row.assumingMemoryBound(to: UInt16.self)[x] = Float16(values[y * width + x]).bitPattern
                } else if format == kCVPixelFormatType_OneComponent32Float {
                    row.assumingMemoryBound(to: Float.self)[x] = values[y * width + x]
                }
            }
        }
        return result
    }

    static func main() throws {
        // A transpose, vertical flip, or interpreting half bits as integers breaks these corners.
        let corners = try buffer([0, 0.25, 0.5, 1], width: 2, height: 2)
        let mapped = try MonocularDepthConversion.raster(corners, imageSize: CGSize(width: 200, height: 200))
        expect(mapped.width == 2 && mapped.height == 2, "square output keeps sample geometry")
        expect(abs(mapped.values[0] - 0.001) < 0.0001, "zero disparity becomes a positive far sample")
        expect(abs(mapped.values[1] - 0.251) < 0.0001, "top-right sample keeps relative disparity")
        expect(abs(mapped.values[2] - 0.501) < 0.0001, "bottom-left stays below top row")
        expect(abs(mapped.values[3] - 1.001) < 0.0001, "larger model value stays nearer")

        // A square-only output, a crop, or a swapped dimension breaks this asymmetric ramp.
        let ramp = try buffer([0, 0.25, 0.5, 0.75, 0, 0.25, 0.5, 0.75], width: 4, height: 2)
        let portrait = try MonocularDepthConversion.raster(ramp, imageSize: CGSize(width: 600, height: 1200))
        expect(portrait.width == 2 && portrait.height == 4, "portrait aspect restored after stretch")
        expect(abs(portrait.values[0] - 0.126) < 0.0001, "left output includes uncropped left half")
        expect(abs(portrait.values[1] - 0.626) < 0.0001, "right output includes uncropped right half")
        expect(portrait.values[0] == portrait.values[6], "vertical resampling preserves constant columns")

        let flat = try buffer(Array(repeating: 0.4, count: 12), width: 4, height: 3,
                              format: kCVPixelFormatType_OneComponent32Float)
        let plane = try MonocularDepthConversion.raster(flat, imageSize: CGSize(width: 400, height: 300))
        expect(plane.values.allSatisfy { abs($0 - 0.401) < 0.0001 }, "constant output remains a plane without invented separation")
        let zeros = try buffer(Array(repeating: 0, count: 12), width: 4, height: 3)
        let zeroPlane = try MonocularDepthConversion.raster(zeros, imageSize: CGSize(width: 400, height: 300))
        expect(zeroPlane.values.allSatisfy { $0 == 0.001 }, "zero plane has valid positive samples without normalization division")
        for value: Float in [.nan, .infinity, -.infinity, -0.2] {
            let invalid = try buffer([0.1, value, 0.3, 0.4], width: 2, height: 2)
            rejects("invalid output must fail, never silently fill a hole") {
                _ = try MonocularDepthConversion.raster(invalid, imageSize: CGSize(width: 200, height: 200))
            }
        }
        let wrongFormat = try buffer([0, 0, 0, 0], width: 2, height: 2, format: kCVPixelFormatType_32BGRA)
        rejects("unsupported output pixel format rejects explicitly") {
            _ = try MonocularDepthConversion.raster(wrongFormat, imageSize: CGSize(width: 200, height: 200))
        }
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 1), CGSize(width: -1, height: 1)] {
            rejects("invalid original geometry rejects") { _ = try MonocularDepthConversion.raster(corners, imageSize: size) }
        }

        let context = CIContext()
        let estimator = MonocularDepthEstimator(context: context)
        // This seam checks the actual image -> model boundary independently of learned output.
        let top = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 150, width: 100, height: 50))
        let bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 150))
        let image = top.composited(over: bottom).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 200))
        let input = try estimator.inputBuffer(for: image, width: 518, height: 392)
        CVPixelBufferLockBaseAddress(input, .readOnly)
        let bytes = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
        let last = CVPixelBufferGetBytesPerRow(input) * 391
        expect(bytes[2] > 240 && bytes[0] < 15, "upright top is first model row, red is RGB red")
        expect(bytes[last] > 240 && bytes[last + 2] < 15, "uncropped bottom survives model preprocessing")
        CVPixelBufferUnlockBaseAddress(input, .readOnly)
        rejects("infinite CIImage extent rejected before loading model") { _ = try estimator.estimate(image: CIImage(color: .white)) }

        if CommandLine.arguments.contains("--expect-missing-model") {
            do {
                _ = try estimator.estimate(image: image)
                expect(false, "missing bundled model must throw its explicit error")
            } catch MonocularDepthError.modelNotBundled {
                expect(true, "missing bundled model rejects explicitly")
            } catch {
                expect(false, "missing bundled model must not be misreported as another failure")
            }
        }

        if CommandLine.arguments.contains("--smoke") {
            let started = Date()
            let result = try estimator.estimate(image: image)
            expect(result.width > 0 && result.height > result.width, "actual model produces portrait result")
            expect(abs(Double(result.width) / Double(result.height) / 0.5 - 1) <= 0.02,
                   "actual model result aspect agrees with full input within 2 percent")
            expect(result.values.allSatisfy { $0.isFinite && $0 > 0 }, "actual inference has finite positive disparity")
            expect(result.values.max()! - result.values.min()! > 0.01, "actual inference has spatial variation")
            // The successful first call must cache the model. Hide only this test's
            // temporary compiled resource while exercising a repeat prediction.
            let modelURL = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc")!
            let hiddenURL = modelURL.appendingPathExtension("temporarily-hidden")
            try FileManager.default.moveItem(at: modelURL, to: hiddenURL)
            defer { try? FileManager.default.moveItem(at: hiddenURL, to: modelURL) }
            let second = try estimator.estimate(image: image)
            expect(zip(second.values, result.values).allSatisfy { abs($0 - $1) < 0.001 }, "cached model yields stable repeat inference")
            print("Actual model smoke: \(result.width)×\(result.height), disparity \(result.values.min()!)…\(result.values.max()!), two calls \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        }
        print("Monocular depth checks: \(checks - failures)/\(checks) passed")
        if failures > 0 { exit(1) }
    }
    enum TestError: Error { case buffer }
}
