// Synthetic Core Image pixels test the app's two-sided depth contract. These
// fixtures do not establish camera quality, hair accuracy, or iPhone latency.
import Foundation
import CoreImage
import CoreGraphics

@main
struct ComputationalDepthRendererTests {
    static var checks = 0
    static var failures = 0
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if condition() { print("PASS: \(label)") }
        else { failures += 1; print("FAIL: \(label)") }
    }

    static func rejects(_ expected: DepthAnalysisError, _ label: String, _ body: () throws -> Void) {
        do { try body(); expect(false, label) }
        catch let error as DepthAnalysisError { expect(error == expected, label) }
        catch { expect(false, "\(label): unexpected \(error)") }
    }

    static func main() throws {
        let renderer = ComputationalDepthRenderer(context: context, colorSpace: colorSpace)
        let original = try fixture(width: 768, height: 512)
        let depth = try twoPlanes()
        let near = NormalizedImagePoint(x: 0.25, y: 0.30)
        let far = NormalizedImagePoint(x: 0.75, y: 0.80)
        let before = pixels(original)
        let focusedNear = try renderer.render(original: original, depth: depth, focus: near, aperture: 1.4)
        let focusedFar = try renderer.render(original: original, depth: depth, focus: far, aperture: 1.4)
        let stoppedDown = try renderer.render(original: original, depth: depth, focus: near, aperture: 16)
        let n = pixels(focusedNear.image), f = pixels(focusedFar.image), s = pixels(stoppedDown.image)

        // A background-only filter, ignored tap, global blur, or identity result
        // each breaks a different one of these image-space assertions.
        expect(texture(n, at: far) < texture(before, at: far)*0.45,
               "Focusing the near plane actually blurs the far texture")
        expect(texture(f, at: near) < texture(before, at: near)*0.45,
               "Focusing the far plane actually blurs the foreground texture")
        expect(difference(before, n, at: near) < 1.5,
               "Near selected plane retains original detail")
        expect(difference(before, f, at: far) < 1.5,
               "Far selected plane retains original detail")
        expect(texture(s, at: far) > texture(n, at: far)*2+2,
               "Closing the aperture reduces defocus at the same focus point")
        expect(focusedNear.image.extent == original.extent && focusedFar.image.extent == original.extent,
               "Both focus choices preserve complete image bounds")
        expect(n.rgba.enumerated().allSatisfy { $0.offset%4 != 3 || $0.element >= 254 },
               "Layer normalization leaves no transparent borders")

        // Unequal off-center geometry and literal TIFF point locations catch
        // swapped axes, reversed depth rows, mirror errors, and cropped output.
        let nearPoints: [(Double, Double)] = [(0.25,0.30),(0.75,0.30),(0.75,0.70),(0.25,0.70),
                                             (0.30,0.25),(0.70,0.25),(0.70,0.75),(0.30,0.75)]
        let farPoints: [(Double, Double)] = [(0.75,0.80),(0.25,0.80),(0.25,0.20),(0.75,0.20),
                                            (0.80,0.75),(0.20,0.75),(0.20,0.25),(0.80,0.25)]
        for exif: UInt32 in 1...8 {
            let transformed = original.oriented(forExifOrientation: Int32(exif))
            let upright = transformed.transformed(by: CGAffineTransform(
                translationX: -transformed.extent.minX, y: -transformed.extent.minY))
            let dp = depth.oriented(exif: exif)
            let np = nearPoints[Int(exif-1)], fp = farPoints[Int(exif-1)]
            let nearPoint = NormalizedImagePoint(x: np.0, y: np.1)
            let farPoint = NormalizedImagePoint(x: fp.0, y: fp.1)
            let nearResult = try renderer.render(original: upright, depth: dp, focus: nearPoint, aperture: 1.4)
            let farResult = try renderer.render(original: upright, depth: dp, focus: farPoint, aperture: 1.4)
            let source = pixels(upright), nearPixels = pixels(nearResult.image), farPixels = pixels(farResult.image)
            let expected = exif < 5 ? CGSize(width: 768, height: 512) : CGSize(width: 512, height: 768)
            expect(nearResult.image.extent == CGRect(origin: .zero, size: expected),
                   "EXIF \(exif): full upright dimensions")
            expect(difference(source, nearPixels, at: nearPoint) < 1.5
                   && texture(nearPixels, at: farPoint) < texture(source, at: farPoint)*0.45,
                   "EXIF \(exif): near tap preserves near pixels and blurs far pixels")
            expect(difference(source, farPixels, at: farPoint) < 1.5
                   && texture(farPixels, at: nearPoint) < texture(source, at: nearPoint)*0.45,
                   "EXIF \(exif): far tap preserves far pixels and blurs near pixels")
        }

        let large = try fixture(width: 2304, height: 1536)
        let largeResult = try renderer.render(original: large, depth: depth, focus: near, aperture: 1.4)
        let largeBefore = pixels(large), largeAfter = pixels(largeResult.image)
        expect(largeResult.image.extent == large.extent, "Large output is never reduced or cropped")
        expect(max(largeResult.amountMask.extent.width, largeResult.amountMask.extent.height) <= 2048,
               "Blur work stays bounded for photos above 2048 pixels")
        expect(difference(largeBefore, largeAfter, at: near) < 1.5,
               "Full-resolution sharp region survives bounded blur processing")
        expect(texture(largeAfter, at: far) < texture(largeBefore, at: far)*0.45,
               "Bounded working layer still blurs full-size distant pixels")
        context.clearCaches()

        let flat = try DepthRaster(width: 96, height: 64, values: .init(repeating: 1, count: 96*64))
        rejects(.insufficientSeparation, "A flat depth plane never invents separation") {
            _ = try renderer.render(original: original, depth: flat, focus: near, aperture: 1.4)
        }
        for point in [NormalizedImagePoint(x: -0.01, y: 0.5), .init(x: .nan, y: 0.5),
                      .init(x: 0.5, y: 1.01), .init(x: 0.5, y: .infinity)] {
            rejects(.focusUnavailable, "Invalid focus coordinates are rejected") {
                _ = try renderer.render(original: original, depth: depth, focus: point, aperture: 1.4)
            }
        }
        var values = depth.values
        for y in 11..<29 { for x in 15..<34 { values[y*96+x] = .nan } }
        let hole = try DepthRaster(width: 96, height: 64, values: values)
        rejects(.focusUnavailable, "A tap inside an unknown depth patch cannot choose a plane") {
            _ = try renderer.render(original: original, depth: hole, focus: near, aperture: 1.4)
        }
        let holeResult = try renderer.render(original: original, depth: hole, focus: far, aperture: 1.4)
        expect(difference(before, pixels(holeResult.image), at: near) < 1.5,
               "Unknown depth stays sharp instead of becoming far background")
        let wrongAspect = try DepthRaster(width: 64, height: 64, values: Array(depth.values.prefix(64*64)))
        rejects(.alignmentMismatch, "A mismatched depth aspect ratio is not stretched into alignment") {
            _ = try renderer.render(original: original, depth: wrongAspect, focus: far, aperture: 1.4)
        }
        print("Computational depth renderer: \(checks) checks, \(failures) failures (synthetic pixels only)")
        if failures > 0 { exit(1) }
    }

    static func twoPlanes() throws -> DepthRaster {
        var values = [Float](repeating: 0.25, count: 96*64)
        for y in 8..<42 { for x in 8..<46 { values[y*96+x] = 1.5 } }
        return try DepthRaster(width: 96, height: 64, values: values)
    }

    static func fixture(width: Int, height: Int) throws -> CIImage {
        var rgba = [UInt8](repeating: 255, count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let value: UInt8 = (x/2+y/2)%2 == 0 ? 35 : 210
            let p = (y*width+x)*4
            rgba[p] = value; rgba[p+1] = value; rgba[p+2] = value
        } }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width*4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw DepthRendererError.imageCreation
        }
        return CIImage(cgImage: image)
    }

    struct Raster { let width: Int; let height: Int; let rgba: [UInt8] }
    static func pixels(_ image: CIImage) -> Raster {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        context.render(image, toBitmap: &bytes, rowBytes: w*4, bounds: image.extent,
                       format: .RGBA8, colorSpace: colorSpace)
        return Raster(width: w, height: h, rgba: bytes)
    }

    static func texture(_ image: Raster, at point: NormalizedImagePoint) -> Double {
        let cx = Int(point.x*Double(image.width)), cy = Int(point.y*Double(image.height))
        var sum = 0.0
        for y in cy-24..<cy+24 { for x in cx-24..<cx+23 {
            let p = (y*image.width+x)*4
            sum += abs(Double(image.rgba[p])-Double(image.rgba[p+4]))
        } }
        return sum/Double(48*47)
    }

    static func difference(_ a: Raster, _ b: Raster, at point: NormalizedImagePoint) -> Double {
        let cx = Int(point.x*Double(a.width)), cy = Int(point.y*Double(a.height))
        var sum = 0.0
        for y in cy-24..<cy+24 { for x in cx-24..<cx+24 {
            let p = (y*a.width+x)*4
            for c in 0..<3 { sum += abs(Double(a.rgba[p+c])-Double(b.rgba[p+c])) }
        } }
        return sum/Double(48*48*3)
    }
}
