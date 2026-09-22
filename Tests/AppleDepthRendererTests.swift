import Foundation
import CoreImage
import ImageIO
import AVFoundation

/// Camera-free HEIC container. RGB is never pre-blurred. All source buffers and
/// auxiliary metadata remain in memory, just like the capture input contract.
enum AppleDepthTestFixture {
    static let width = 768
    static let height = 512
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func photo(context: CIContext, orientation: UInt32 = 1,
                      includeDepth: Bool = true, disparityValue: ((Int, Int) -> Float)? = nil) throws -> Data {
        let w = width, h = height
        var pixels = [UInt8](repeating: 255, count: w*h*4)
        var disparity = [Float](repeating: 0, count: w*h)
        for y in 0..<h {
            for x in 0..<w {
                let quadrant = (y < h/2 ? 0 : 2) + (x < w/2 ? 0 : 1)
                let p = (y*w+x)*4
                let light: UInt8 = (x/5+y/5)%2 == 0 ? 40 : 200
                pixels[p] = light
                pixels[p+1] = light + UInt8(quadrant*12)
                pixels[p+2] = light
                disparity[y*w+x] = disparityValue?(x, y) ?? [0.9, 0.65, 0.4, 0.1][quadrant]
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: w*4,
                            size: CGSize(width: w, height: h), format: .RGBA8,
                            colorSpace: colorSpace)
        guard let cg = context.createCGImage(image, from: image.extent) else {
            throw FixtureError.encoding
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, "public.heic" as CFString, 1, nil) else {
            throw FixtureError.encoding
        }
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: orientation,
                                                     kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        if includeDepth {
            let metadata = CGImageMetadataCreateMutable()
            CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.apple.com/depthData/1.0/" as CFString,
                                                     "depthData" as CFString, nil)
            CGImageMetadataSetValueWithPath(metadata, nil, "depthData:Accuracy" as CFString, "relative" as CFString)
            CGImageMetadataSetValueWithPath(metadata, nil, "depthData:Quality" as CFString, "high" as CFString)
            CGImageMetadataSetValueWithPath(metadata, nil, "depthData:Filtered" as CFString, true as CFTypeRef)
            let description: [String: Any] = [
                kCGImagePropertyWidth as String: w, kCGImagePropertyHeight as String: h,
                kCGImagePropertyBytesPerRow as String: w*4,
                kCGImagePropertyPixelFormat as String: kCVPixelFormatType_DisparityFloat32,
                kCGImagePropertyOrientation as String: 1
            ]
            let auxiliary: [String: Any] = [
                kCGImageAuxiliaryDataInfoData as String: disparity.withUnsafeBytes { Data($0) },
                kCGImageAuxiliaryDataInfoDataDescription as String: description,
                kCGImageAuxiliaryDataInfoMetadata as String: metadata
            ]
            let depth = try AVDepthData(fromDictionaryRepresentation: auxiliary)
            var type: NSString?
            guard let serial = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat16)
                .dictionaryRepresentation(forAuxiliaryDataType: &type) else { throw FixtureError.encoding }
            CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDisparity, serial as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.encoding }
        return buffer as Data
    }

    enum FixtureError: Error { case encoding }
}

#if APPLE_DEPTH_TEST_MAIN
@main
struct AppleDepthRendererTests {
    static var failures = 0
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); expect(false, message) } catch { expect(true, message) }
    }

    static func main() throws {
        let context = CIContext()
        let renderer = AppleDepthRenderer(context: context)
        let noDepth = try AppleDepthTestFixture.photo(context: context, includeDepth: false)
        rejects("RGB-only photo must explicitly reject missing auxiliary depth") {
            _ = try renderer.render(photoData: noDepth, aperture: 1.4, sensorFocus: nil)
        }
        rejects("invalid container must throw") {
            _ = try renderer.render(photoData: Data([1,2,3]), aperture: 1.4, sensorFocus: nil)
        }
        for (label, value): (String, Float) in [("zero", 0), ("NaN", .nan), ("infinity", .infinity)] {
            let invalidDepth = try AppleDepthTestFixture.photo(context: context, disparityValue: { _, _ in value })
            do {
                _ = try renderer.render(photoData: invalidDepth, aperture: 1.4, sensorFocus: nil)
                expect(false, "all-\(label) auxiliary depth must throw invalidDepth")
            } catch AppleDepthRenderingError.invalidDepth {
                expect(true, "all-\(label) auxiliary depth is rejected")
            } catch AppleDepthRenderingError.missingDepth where !value.isFinite {
                // ImageIO may omit an auxiliary image with no finite samples.
                // In that encoded container, missingDepth is the correct error.
                let source = CGImageSourceCreateWithData(invalidDepth as CFData, nil)!
                expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) == nil,
                       "all-nonfinite depth omitted by ImageIO must not be treated as usable depth")
            } catch {
                expect(false, "all-\(label) must reject invalidDepth, not another error")
            }
        }
        let sparse = try AppleDepthTestFixture.photo(context: context, disparityValue: { x, _ in
            x < AppleDepthTestFixture.width/8 ? 0.5 : 0
        })
        do {
            _ = try renderer.render(photoData: sparse, aperture: 1.4, sensorFocus: nil)
            expect(false, "less than a quarter finite positive depth must be rejected")
        } catch AppleDepthRenderingError.invalidDepth {
            expect(true, "sparse depth is rejected before filtering")
        }
        let quarter = try AppleDepthTestFixture.photo(context: context, disparityValue: { x, _ in
            x < AppleDepthTestFixture.width/4 ? 0.5 : 0
        })
        let quarterResult = try renderer.render(photoData: quarter, aperture: 1.4, sensorFocus: nil)
        expect(raster(quarterResult.image, context).pixels.contains { $0 != 0 },
               "exactly a quarter finite positive depth meets the validity threshold")
        let flatDepth = try AppleDepthTestFixture.photo(context: context, disparityValue: { _, _ in 0.5 })
        let flatResult = try renderer.render(photoData: flatDepth, aperture: 1.4, sensorFocus: nil)
        expect(raster(flatResult.image, context).pixels.contains { $0 != 0 },
               "finite positive constant depth remains a valid plane")
        let photo = try AppleDepthTestFixture.photo(context: context)
        for aperture: Float in [.nan, .infinity, -.infinity, 0, -1, 0.5, .leastNonzeroMagnitude, 23] {
            rejects("invalid aperture must throw before calling Core Image") {
                _ = try renderer.render(photoData: photo, aperture: aperture, sensorFocus: nil)
            }
        }
        for point in [NormalizedImagePoint(x: .nan, y: 0.4), .init(x: 0.4, y: .infinity),
                      .init(x: -0.1, y: 0.4), .init(x: 1.1, y: 0.4)] {
            rejects("invalid focus must throw before calling Core Image") {
                _ = try renderer.render(photoData: photo, aperture: 1.4, sensorFocus: point)
            }
        }
        let native = context.depthBlurEffectFilter(forImageData: photo)!
        native.setValue(1.4, forKey: "inputAperture")
        native.setValue(CIVector(x: 0.21, y: 0.72, z: 0.02, w: 0.02), forKey: "inputFocusRect")
        let nativeInput = native.value(forKey: kCIInputImageKey) as! CIImage
        let nativeOutput = native.outputImage!
        if nativeOutput === nativeInput {
            // Characterize the system bypass with real rendering, not only an
            // object identity check. Metadata compatibility must be disclosed.
            expect(raster(nativeInput, context).pixels == raster(nativeOutput, context).pixels,
                   "factory identity bypass must have exactly unchanged rendered pixels")
            let result = try renderer.render(photoData: photo, aperture: 1.4, sensorFocus: .init(x: 0.22, y: 0.27))
            expect(result.usedMetadataCompatibility, "metadata bypass must be reported as compatibility rendering")
            expect(!result.notes.isEmpty, "compatibility rendering requires a user-visible explanation")
        }
        let defaultFocus = try renderer.render(photoData: photo, aperture: 1.4, sensorFocus: nil)
        expect(defaultFocus.image.extent.size == CGSize(width: 768, height: 512), "native default focus is supported")
        for point in [NormalizedImagePoint(x: 0, y: 0), .init(x: 1, y: 1)] {
            let edge = try renderer.render(photoData: photo, aperture: 1.4, sensorFocus: point)
            expect(raster(edge.image, context).pixels.contains { $0 != 0 }, "edge focus renders without invalid ROI")
        }
        // Hard-coded top-left coordinates after each TIFF orientation; never use
        // the production orientation helper to compute the test oracle.
        let nearPoints: [(Double, Double)] = [(0.22,0.27),(0.78,0.27),(0.78,0.73),(0.22,0.73),
                                             (0.27,0.22),(0.73,0.22),(0.73,0.78),(0.27,0.78)]
        let farPoints: [(Double, Double)] = [(0.72,0.71),(0.28,0.71),(0.28,0.29),(0.72,0.29),
                                            (0.71,0.72),(0.29,0.72),(0.29,0.28),(0.71,0.28)]
        for orientation: UInt32 in 1...8 {
            let data = try AppleDepthTestFixture.photo(context: context, orientation: orientation)
            let near = try renderer.render(photoData: data, aperture: 1.4, sensorFocus: .init(x: 0.22, y: 0.27)).image
            let far = try renderer.render(photoData: data, aperture: 1.4, sensorFocus: .init(x: 0.72, y: 0.71)).image
            let stopped = try renderer.render(photoData: data, aperture: 16, sensorFocus: .init(x: 0.22, y: 0.27)).image
            let expected = orientation < 5 ? CGSize(width: 768, height: 512) : CGSize(width: 512, height: 768)
            expect(near.extent == CGRect(origin: .zero, size: expected), "EXIF \(orientation): upright size and origin")
            let n = raster(near, context), f = raster(far, context), s = raster(stopped, context)
            let point = farPoints[Int(orientation-1)]
            let nearPoint = nearPoints[Int(orientation-1)]
            let unfocused = texture(n, point), focused = texture(f, point), closed = texture(s, point)
            print(String(format: "EXIF %d: far texture near-focus %.3f / far-focus %.3f / f16 %.3f", orientation, unfocused, focused, closed))
            expect(focused > unfocused*1.4+1, "EXIF \(orientation): focus must sharpen the selected distant texture")
            expect(closed > unfocused*1.2+0.5, "EXIF \(orientation): f/16 must retain more distant texture than f/1.4")
            expect(texture(n, nearPoint) > unfocused*1.4+1, "EXIF \(orientation): near focus retains selected near texture")
        }
        print("Apple depth renderer: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
    struct Raster { let width: Int; let height: Int; let pixels: [UInt8] }
    static func raster(_ image: CIImage, _ context: CIContext) -> Raster {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        context.render(image, toBitmap: &pixels, rowBytes: w*4, bounds: image.extent,
                       format: .RGBA8, colorSpace: AppleDepthTestFixture.colorSpace)
        return Raster(width: w, height: h, pixels: pixels)
    }
    static func texture(_ image: Raster, _ point: (Double, Double)) -> Double {
        let cx = Int(point.0*Double(image.width)), cy = Int(point.1*Double(image.height))
        var sum = 0.0
        for y in cy-32..<cy+32 {
            for x in cx-32..<cx+31 {
                let p = (y*image.width+x)*4
                sum += abs(Double(image.pixels[p])-Double(image.pixels[p+4]))
            }
        }
        return sum/Double(64*63)
    }
}
#endif
