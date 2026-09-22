// 在 macOS + Xcode 上编译执行，真正调用 Core Image / Vision / Image I/O。
// 所有图片/深度为代码生成的测试夹具，不使用用户参考照片，不冒充真机效果验证。
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

@main
struct NativeRenderSmokeTests {
    static var checks = 0
    static var failures = 0
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if condition() { print("PASS: \(name)") }
        else { failures += 1; print("FAIL: \(name)") }
    }

    static func main() async throws {
        let fixture = try makeFixture(width: 400, height: 300, uniform: false)
        let original = CIImage(cgImage: fixture.image)
        let plan = try DepthMath.makePlan(depth: fixture.depth,
            focus: NormalizedImagePoint(x: 0.5, y: 0.5), isPerson: false, aperture: 1.4)
        let renderer = DepthBlurRenderer(context: context, colorSpace: srgb)
        let result = try renderer.render(original: original, plan: plan)
        let before = rgba(original, width: 400, height: 300)
        let after = rgba(result.image, width: 400, height: 300)
        expect(result.image.extent == original.extent, "Native output dimensions unchanged")
        expect(contrast(after, width: 400, x: 25..<85) < contrast(before, width: 400, x: 25..<85)*0.6,
               "Actual near-region texture is blurred")
        expect(contrast(after, width: 400, x: 315..<375) < contrast(before, width: 400, x: 315..<375)*0.6,
               "Actual far-region texture is blurred")
        expect(meanDifference(before, after, width: 400, x: 175..<225) < 1.5,
               "In-focus texture retained, not globally blurred")
        expect(stride(from: 3, to: after.count, by: 4).allSatisfy { after[$0] >= 254 }, "No transparent output borders")

        // 对全部 8 个 EXIF 方向验证：视差选区与 Core Image 图像变换一致。
        for exif in UInt32(1)...8 {
            let oriented = original.oriented(forExifOrientation: Int32(exif))
            let normalized = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX,
                                                                         y: -oriented.extent.minY))
            let rotatedDepth = fixture.depth.oriented(exif: exif)
            let center = NormalizedImagePoint(x: 0.5, y: 0.5).oriented(exif: exif)
            let rotatedPlan = try DepthMath.makePlan(depth: rotatedDepth, focus: center, isPerson: false, aperture: 1.4)
            let rotated = try renderer.render(original: normalized, plan: rotatedPlan)
            let w = Int(normalized.extent.width), h = Int(normalized.extent.height)
            let mask = rgba(rotated.amountMask, width: w, height: h, colorSpace: nil)
            let near = NormalizedImagePoint(x: 0.15, y: 0.5).oriented(exif: exif)
            let far = NormalizedImagePoint(x: 0.85, y: 0.5).oriented(exif: exif)
            expect(sample(mask, width: w, height: h, at: center) < 8, "Native mask focus EXIF \(exif)")
            expect(sample(mask, width: w, height: h, at: near) > 220, "Native mask near EXIF \(exif)")
            expect(sample(mask, width: w, height: h, at: far) > 220, "Native mask far EXIF \(exif)")
        }

        // The old vertical bands and centered focus are symmetric in y, so they
        // cannot catch a flipped scanline or a rotated mask landing on another object.
        // These unequal, off-center rectangles have literal hand-derived positions
        // for every EXIF orientation, checked against both the mask and actual pixels.
        var asymmetricValues = [Float](repeating: 0.4, count: 400*300)
        for y in 45..<135 { for x in 230..<345 { asymmetricValues[y*400+x] = 1 } }
        for y in 165..<255 { for x in 40..<120 { asymmetricValues[y*400+x] = 1.8 } }
        let asymmetricDepth = try DepthRaster(width: 400, height: 300, values: asymmetricValues)
        let positions: [(UInt32, (Double, Double), (Double, Double), (Double, Double))] = [
            (1, (0.7, 0.3), (0.2, 0.7), (0.55, 0.8)),
            (2, (0.3, 0.3), (0.8, 0.7), (0.45, 0.8)),
            (3, (0.3, 0.7), (0.8, 0.3), (0.45, 0.2)),
            (4, (0.7, 0.7), (0.2, 0.3), (0.55, 0.2)),
            (5, (0.3, 0.7), (0.7, 0.2), (0.8, 0.55)),
            (6, (0.7, 0.7), (0.3, 0.2), (0.2, 0.55)),
            (7, (0.7, 0.3), (0.3, 0.8), (0.2, 0.45)),
            (8, (0.3, 0.3), (0.7, 0.8), (0.8, 0.45))
        ]
        for (exif, focusXY, nearXY, farXY) in positions {
            let oriented = original.oriented(forExifOrientation: Int32(exif))
            let normalized = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX,
                                                                         y: -oriented.extent.minY))
            let focus = NormalizedImagePoint(x: focusXY.0, y: focusXY.1)
            let near = NormalizedImagePoint(x: nearXY.0, y: nearXY.1)
            let far = NormalizedImagePoint(x: farXY.0, y: farXY.1)
            let orientedPlan = try DepthMath.makePlan(depth: asymmetricDepth.oriented(exif: exif),
                                                     focus: focus, isPerson: false, aperture: 1.4)
            let orientedResult = try renderer.render(original: normalized, plan: orientedPlan)
            let w = Int(normalized.extent.width), h = Int(normalized.extent.height)
            let mask = rgba(orientedResult.amountMask, width: w, height: h, colorSpace: nil)
            expect(sample(mask, width: w, height: h, at: focus) < 8,
                   "Asymmetric mask retains the off-center focus EXIF \(exif)")
            expect(sample(mask, width: w, height: h, at: near) > 220
                   && sample(mask, width: w, height: h, at: far) > 220,
                   "Asymmetric mask finds the correct near and far objects EXIF \(exif)")
            let before = rgba(normalized, width: w, height: h)
            let after = rgba(orientedResult.image, width: w, height: h)
            expect(patchDifference(before, after, width: w, height: h, at: focus) < 1.5,
                   "Asymmetric off-center subject texture stays sharp EXIF \(exif)")
            expect(patchContrast(after, width: w, height: h, at: near)
                   < patchContrast(before, width: w, height: h, at: near)*0.6
                   && patchContrast(after, width: w, height: h, at: far)
                   < patchContrast(before, width: w, height: h, at: far)*0.6,
                   "Asymmetric near and far textures actually blur EXIF \(exif)")
        }

        // 常量颜色 + 变化深度。归一化/alpha 若错误，边界会变黑或变亮，此测试必须失败。
        let uniform = try makeFixture(width: 400, height: 300, uniform: true)
        let uniformImage = CIImage(cgImage: uniform.image)
        let uniformResult = try renderer.render(original: uniformImage, plan: plan)
        let uniformPixels = rgba(uniformResult.image, width: 400, height: 300)
        let uniformBefore = rgba(uniformImage, width: 400, height: 300)
        let error = zip(uniformPixels, uniformBefore).map { abs(Int($0)-Int($1)) }.reduce(0, +)
        expect(Double(error)/Double(uniformPixels.count) < 1.5, "Coverage normalization preserves uniform color at occlusions")

        // 覆盖 2048 虚化层限幅分支；清晰部分必须仍来自完整分辨率原图。
        let large = try makeFixture(width: 2400, height: 1800, uniform: false)
        let largePlan = try DepthMath.makePlan(depth: large.depth,
            focus: NormalizedImagePoint(x: 0.5, y: 0.5), isPerson: false, aperture: 1.4)
        let largeImage = CIImage(cgImage: large.image)
        let largeResult = try renderer.render(original: largeImage, plan: largePlan)
        let a = rgba(largeImage, width: 2400, height: 1800)
        let b = rgba(largeResult.image, width: 2400, height: 1800)
        expect(meanDifference(a, b, width: 2400, x: 1150..<1250) < 1.5,
               "Downsampled blur layer does not downsample the sharp region")
        context.clearCaches()

        // The subject includes pixels that depth places in both the near and far
        // blur layers. An explicit white protection mask must preserve those pixels
        // and the adjacent clear edge, including at full resolution above 2048 px.
        // This catches merely passing a mask through without applying it, protecting
        // only the far layer, or letting expanded near blur bleed back over a person.
        for size in [(400, 300), (2400, 1800)] {
            let w = size.0, h = size.1
            let protectedFixture = try makeFixture(width: w, height: h, uniform: false)
            let protectedOriginal = CIImage(cgImage: protectedFixture.image)
            let protectedPlan = try DepthMath.makePlan(depth: protectedFixture.depth,
                focus: NormalizedImagePoint(x: 0.5, y: 0.5), isPerson: false, aperture: 1.4)
            let extent = protectedOriginal.extent
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            let nearSubject = white.cropped(to: CGRect(x: Double(w)*0.2, y: Double(h)*0.2,
                                                       width: Double(w)*0.2, height: Double(h)*0.6))
            let farSubject = white.cropped(to: CGRect(x: Double(w)*0.725, y: Double(h)*0.2,
                                                      width: Double(w)*0.175, height: Double(h)*0.6))
            let subject = nearSubject.composited(over: farSubject.composited(over: black))
            let protected = try renderer.render(original: protectedOriginal, plan: protectedPlan,
                                                  protectedSubject: subject)
            let protectedBefore = rgba(protectedOriginal, width: w, height: h)
            let protectedAfter = rgba(protected.image, width: w, height: h)
            expect(meanDifference(protectedBefore, protectedAfter, width: w,
                                  x: Int(Double(w)*0.23)..<Int(Double(w)*0.27)) < 1.5,
                   "Protected near-depth subject retains original texture at \(w)x\(h)")
            expect(meanDifference(protectedBefore, protectedAfter, width: w,
                                  x: Int(Double(w)*0.79)..<Int(Double(w)*0.85)) < 1.5,
                   "Protected far-depth subject retains original texture at \(w)x\(h)")
            expect(meanDifference(protectedBefore, protectedAfter, width: w,
                                  x: Int(Double(w)*0.3025)..<Int(Double(w)*0.32)) < 1.5,
                   "Expanded foreground blur cannot contaminate protected subject edge at \(w)x\(h)")
            let backdrop = Int(Double(w)*0.93)..<Int(Double(w)*0.98)
            expect(contrast(protectedAfter, width: w, x: backdrop)
                   < contrast(protectedBefore, width: w, x: backdrop)*0.6,
                   "Background outside protected subject remains blurred at \(w)x\(h)")
            context.clearCaches()
        }

        // 输入 PNG 没有 HEIC 深度附件，直接传入的深度仍要生效。
        let png = try encodePNG(fixture.image)
        let snapshot = NativeDepthSnapshot(raster: fixture.depth, quality: "synthetic", accuracy: "relative", filtered: true)
        let processor = DepthPhotoProcessor()
        // 默认苹果路径需要保留原生辅助元数据的采集容器；不得偷偷使用旧版算法冒充。
        let noContainer = try await processor.process(CapturedPhoto(data: png, depthRequested: true,
            hasDepthData: true, nativeDepth: snapshot, options: DepthOptions(enabled: true, aperture: 1.4),
            transientDeviceFocus: NormalizedImagePoint(x: 0.5, y: 0.5), captureSummary: "missing native auxiliary container"),
            renderer: .apple, includeLegacyComparison: true)
        expect(noContainer.outcome == .renderFailed,
               "Explicit Apple renderer never silently substitutes other blur when native input is missing")
        expect(noContainer.diagnosticMaskData == nil,
               "Failed Apple rendering never publishes a fabricated blur mask")
        expect(noContainer.legacyComparison?.outcome == .applied,
               "Same-frame legacy comparison remains available without replacing failed Apple output")
        let valid = try await processor.process(CapturedPhoto(data: png, depthRequested: true,
            hasDepthData: true, nativeDepth: snapshot, options: DepthOptions(enabled: true, aperture: 1.4),
            transientDeviceFocus: NormalizedImagePoint(x: 0.5, y: 0.5), captureSummary: "synthetic renderer fixture"), renderer: .legacy)
        expect(valid.outcome == .applied, "Full pipeline sees measurable output change without embedded depth")
        expect(valid.diagnosticMaskData != nil, "Diagnostic mask comes from actual render")
        expect(valid.pixelWidth == 400 && valid.pixelHeight == 300, "Export size matches captured image")
        let source = CGImageSourceCreateWithData(valid.jpegData as CFData, nil)!
        expect(CGImageSourceGetCount(source) == 1, "Export is a single baked photo")
        expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth) == nil,
               "No depth attachment is saved")
        expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) == nil,
               "No disparity attachment is saved")
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        expect(properties[kCGImagePropertyMakerAppleDictionary as String] == nil, "No private camera/focus metadata copied")

        let missing = try await processor.process(CapturedPhoto(data: png, depthRequested: true,
            hasDepthData: false, nativeDepth: nil, options: DepthOptions(enabled: true, aperture: 1.4),
            transientDeviceFocus: nil, captureSummary: "synthetic missing-depth case"), renderer: .apple)
        expect(missing.outcome == .missingDepth, "Missing depth reports ordinary-photo fallback")
        expect(missing.diagnosticMaskData == nil, "Missing depth does not fabricate a mask")
        expect(noContainer.jpegData == missing.jpegData,
               "Saving after legacy comparison still saves the primary ordinary-photo fallback")
        expect(noContainer.legacyComparison?.previewData != missing.previewData,
               "Legacy comparison contains a separately rendered preview, not a copy of the primary")
        let disabled = try await processor.process(CapturedPhoto(data: png, depthRequested: false,
            hasDepthData: false, nativeDepth: nil, options: DepthOptions(enabled: false, aperture: 1.4),
            transientDeviceFocus: nil, captureSummary: "synthetic disabled case"))
        expect(disabled.outcome == .disabled, "User disabling depth is preserved")
        let plainUniform = try await processor.process(CapturedPhoto(data: encodePNG(uniform.image), depthRequested: true,
            hasDepthData: true, nativeDepth: snapshot, options: DepthOptions(enabled: true, aperture: 1.4),
            transientDeviceFocus: NormalizedImagePoint(x: 0.5, y: 0.5), captureSummary: "synthetic uniform-color case"), renderer: .legacy)
        expect(plainUniform.outcome == .weakEffect, "Uniform background is not falsely labelled visibly changed")

        // 真实编码的同帧 RGB + disparity 容器走默认苹果路径，而非只测适配器。
        let appleInput = try AppleDepthTestFixture.photo(context: context)
        let appleSource = CGImageSourceCreateWithData(appleInput as CFData, nil)!
        let appleAuxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(appleSource, 0,
            kCGImageAuxiliaryDataTypeDisparity)! as! [AnyHashable: Any]
        let appleSnapshot = try NativeDepthSnapshot(depthData: AVDepthData(fromDictionaryRepresentation: appleAuxiliary))
        let applePhoto = CapturedPhoto(data: appleInput, depthRequested: true, hasDepthData: true,
            nativeDepth: appleSnapshot, options: DepthOptions(enabled: true, aperture: 1.4),
            transientDeviceFocus: .init(x: 0.22, y: 0.27), captureSummary: "unblurred same-frame Apple fixture")
        let appleResult = try await processor.process(applePhoto, renderer: .apple, includeLegacyComparison: true)
        expect(appleResult.outcome == .applied, "Default Apple pipeline produces measured changes from native auxiliary data")
        expect(appleResult.legacyComparison?.outcome == .applied, "Same-frame legacy renderer runs independently")
        expect(appleResult.legacyComparison?.previewData != appleResult.previewData,
               "Apple and legacy comparison previews contain their respective rendered output")
        expect(appleResult.pixelWidth == 768 && appleResult.pixelHeight == 512,
               "Apple processing preserves complete capture dimensions")
        expect(appleResult.diagnosticMaskData != nil && appleResult.diagnosticImageIsDifference,
               "Apple diagnostic explicitly identifies an output difference image")
        let appleExport = CGImageSourceCreateWithData(appleResult.jpegData as CFData, nil)!
        expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(appleExport, 0, kCGImageAuxiliaryDataTypeDisparity) == nil,
               "Apple input disparity is stripped from the baked JPEG export")
        let appleProperties = CGImageSourceCopyPropertiesAtIndex(appleExport, 0, nil) as? [String: Any] ?? [:]
        expect(appleProperties[kCGImagePropertyMakerAppleDictionary as String] == nil,
               "Apple rendering does not persist private focus/camera metadata")
        print("\n\(checks) native checks; \(failures) failures. These are synthetic tests, NOT an iPhone camera test.")
        if failures > 0 { exit(1) }
    }

    static func makeFixture(width: Int, height: Int, uniform: Bool) throws -> (image: CGImage, depth: DepthRaster) {
        var pixels = [UInt8](repeating: 255, count: width*height*4)
        var depth = [Float](repeating: 1, count: width*height)
        for y in 0..<height {
            for x in 0..<width {
                let p = (y*width+x)*4
                let v: UInt8 = uniform ? 146 : ((x/3+y/3)%2 == 0 ? 40 : 210)
                pixels[p] = v; pixels[p+1] = v; pixels[p+2] = v
                depth[y*width+x] = x < width*3/10 ? 2 : (x > width*7/10 ? 0.25 : 1)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width*4, space: srgb,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw DepthRendererError.imageCreation
        }
        return (image, try DepthRaster(width: width, height: height, values: depth))
    }
    static func rgba(_ image: CIImage, width: Int, height: Int, colorSpace: CGColorSpace? = srgb) -> [UInt8] {
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width)/image.extent.width,
                                                             y: CGFloat(height)/image.extent.height))
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        pixels.withUnsafeMutableBytes {
            context.render(scaled, toBitmap: $0.baseAddress!, rowBytes: width*4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
        }
        return pixels
    }
    static func sample(_ pixels: [UInt8], width: Int, height: Int, at p: NormalizedImagePoint) -> UInt8 {
        let x = min(width-1, max(0, Int(p.x*Double(width))))
        // CIContext.render(toBitmap:) writes the first scanline at the top. The
        // point already uses top-left image coordinates; flipping y samples another row.
        let y = min(height-1, max(0, Int(p.y*Double(height))))
        return pixels[(y*width+x)*4]
    }
    static func contrast(_ pixels: [UInt8], width: Int, x: Range<Int>) -> Double {
        let height = pixels.count/(width*4)
        var sum = 0.0, sum2 = 0.0, count = 0.0
        for y in height/4..<height*3/4 {
            for i in x {
                let v = Double(pixels[(y*width+i)*4]); sum += v; sum2 += v*v; count += 1
            }
        }
        return sqrt(max(0, sum2/count - (sum/count)*(sum/count)))
    }
    static func patchDifference(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int,
                                at point: NormalizedImagePoint) -> Double {
        let cx = Int(point.x*Double(width)), cy = Int(point.y*Double(height))
        var sum = 0.0
        for y in (cy-12)..<(cy+12) { for x in (cx-12)..<(cx+12) {
            sum += Double(abs(Int(a[(y*width+x)*4])-Int(b[(y*width+x)*4])))
        } }
        return sum/(24*24)
    }

    static func patchContrast(_ pixels: [UInt8], width: Int, height: Int,
                              at point: NormalizedImagePoint) -> Double {
        let cx = Int(point.x*Double(width)), cy = Int(point.y*Double(height))
        var sum = 0.0, sum2 = 0.0
        for y in (cy-12)..<(cy+12) { for x in (cx-12)..<(cx+12) {
            let v = Double(pixels[(y*width+x)*4]); sum += v; sum2 += v*v
        } }
        let count = Double(24*24)
        return sqrt(max(0, sum2/count - (sum/count)*(sum/count)))
    }

    static func meanDifference(_ a: [UInt8], _ b: [UInt8], width: Int, x: Range<Int>) -> Double {
        let height = a.count/(width*4)
        var sum = 0.0, count = 0.0
        for y in height/4..<height*3/4 { for i in x {
            sum += Double(abs(Int(a[(y*width+i)*4])-Int(b[(y*width+i)*4]))); count += 1
        } }
        return sum/count
    }
    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw DepthRendererError.imageCreation
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DepthRendererError.imageCreation }
        return data as Data
    }
}
