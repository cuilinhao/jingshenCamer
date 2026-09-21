import Foundation
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// 真正编码带深度的 HEIC，再调用生产处理器；用区域像素变化验证虚化，不检查固定输出字节。
@main
struct DepthRenderingTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Raster {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        func difference(from other: Raster, in rect: CGRect) -> Double {
            precondition(width == other.width && height == other.height)
            var sum = 0.0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let offset = (y * width + x) * 4
                    for channel in 0..<3 {
                        sum += abs(Double(rgba[offset + channel]) - Double(other.rgba[offset + channel]))
                    }
                }
            }
            return sum / (rect.width * rect.height * 3)
        }
    }

    static let width = 640
    static let height = 480
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: "FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func fixture(orientation: UInt32 = 1, constantDepth: Bool = false,
                        embedsDepth: Bool = true, checkerSize: Int = 6) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var disparity = [Float](repeating: 10, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let value: UInt8 = (x / checkerSize + y / checkerSize).isMultiple(of: 2) ? 220 : 30
                for channel in 0..<3 { pixels[index * 4 + channel] = value }
                // 左上坐标：近景主体中心 (0.2, 0.3)，横向、纵向都不在图像中心。
                if !constantDepth && (48..<208).contains(x) && (64..<224).contains(y) {
                    disparity[index] = 10.1
                }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4,
                            size: CGSize(width: width, height: height), format: .RGBA8,
                            colorSpace: colorSpace)
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw Failure(description: "Cannot create fixture image")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw Failure(description: "HEIC encoder unavailable")
        }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1
        ] as CFDictionary)
        if embedsDepth {
            let depth = try AVDepthData(fromDictionaryRepresentation: [
                kCGImageAuxiliaryDataInfoData: disparity.withUnsafeBytes { Data($0) },
                kCGImageAuxiliaryDataInfoDataDescription: [
                    kCGImagePropertyPixelFormat: kCVPixelFormatType_DisparityFloat32,
                    kCGImagePropertyWidth: width,
                    kCGImagePropertyHeight: height,
                    kCGImagePropertyBytesPerRow: width * 4
                ]
            ])
            var type: NSString?
            guard let info = depth.dictionaryRepresentation(forAuxiliaryDataType: &type), let type else {
                throw Failure(description: "Cannot encode fixture depth")
            }
            CGImageDestinationAddAuxiliaryDataInfo(destination, type as CFString, info as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "HEIC fixture encoding failed")
        }
        return data as Data
    }

    static func raster(_ data: Data) throws -> Raster {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw Failure(description: "Cannot decode rendered JPEG")
        }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: image.extent,
                           format: .RGBA8, colorSpace: colorSpace)
        return Raster(width: w, height: h, rgba: bytes)
    }

    static func render(_ data: Data, enabled: Bool = true, aperture: Float = 1.4,
                       focus: CGPoint? = CGPoint(x: 0.2, y: 0.3),
                       hasDepth: Bool = true, requested: Bool = true) async throws -> ProcessedPhoto {
        let options = DepthOptions(enabled: enabled, aperture: aperture, focusPoint: focus)
        return try await DepthPhotoProcessor().process(CapturedPhoto(
            data: data, depthRequested: requested, hasDepthData: hasDepth, options: options))
    }

    static func run() async throws {
        let data = try fixture()
        let plain = try await render(data, enabled: false)
        let sharp = try raster(plain.jpegData)
        let strong = try await render(data)
        let strongRaster = try raster(strong.jpegData)
        let subject = CGRect(x: 88, y: 104, width: 80, height: 80)
        let background = CGRect(x: 400, y: 280, width: 160, height: 120)
        let backgroundChange = strongRaster.difference(from: sharp, in: background)
        let subjectChange = strongRaster.difference(from: sharp, in: subject)
        print(String(format: "偏心主体: background=%.4f, subject=%.4f", backgroundChange, subjectChange))
        try check(backgroundChange > 1.5, "点按偏离中心的主体后，背景必须产生可见虚化")
        try check(subjectChange < 3, "主体内部保持清晰")
        try check(strong.outcome.isDepthApplied, "有效景深成片报告成功")
        try check(plain.outcome == .disabled, "关闭景深保留普通照片")
        try check(strong.pixelWidth == width && strong.pixelHeight == height,
                  "输出像素尺寸保持原始照片大小")
        guard let exported = CGImageSourceCreateWithData(strong.jpegData as CFData, nil) else {
            throw Failure(description: "Cannot inspect exported JPEG")
        }
        try check(CGImageSourceGetType(exported) == UTType.jpeg.identifier as CFString,
                  "保存数据为普通 JPEG")
        try check(CGImageSourceCopyAuxiliaryDataInfoAtIndex(exported, 0, kCGImageAuxiliaryDataTypeDisparity) == nil
                  && CGImageSourceCopyAuxiliaryDataInfoAtIndex(exported, 0, kCGImageAuxiliaryDataTypeDepth) == nil,
                  "导出成片不包含可重编辑的辅助深度")

        let weak = try await render(data, aperture: 16)
        let weakRaster = try raster(weak.jpegData)
        let weakChange = weakRaster.difference(from: sharp, in: background)
        try check(backgroundChange > weakChange + 1, "f/1.4 的背景虚化明显强于 f/16")

        // 先缩小再比较会抹掉细纹理差异，误把真实虚化结果替换为原图。
        let fineData = try fixture(checkerSize: 2)
        let fineBefore = try raster(try await render(fineData, enabled: false).jpegData)
        let fineResult = try await render(fineData)
        let fineAfter = try raster(fineResult.jpegData)
        try check(fineResult.outcome.isDepthApplied && fineAfter.difference(from: fineBefore, in: background) > 1.5,
                  "细密纹理的有效虚化不能被缩小采样误判并丢弃")

        let automatic = try await render(data, focus: nil)
        let automaticRaster = try raster(automatic.jpegData)
        try check(automaticRaster.difference(from: sharp, in: background) > 1.5,
                  "没有点按时也能为偏心近景选择有效焦点")
        try check(automaticRaster.difference(from: sharp, in: subject) < 3,
                  "自动选择焦点保留近景主体细节")

        let backgroundFocus = try await render(data, focus: CGPoint(x: 0.8, y: 0.7))
        try check(backgroundFocus.outcome == .noVisibleEffect,
                  "有效深度却未改变像素时不能误报景深成片")

        // 手工推导的左上像素坐标；不用生产转换函数计算期望值。
        let orientations: [(UInt32, Int, Int, CGRect, CGRect)] = [
            (2, 640, 480, CGRect(x: 472, y: 104, width: 80, height: 80),
             CGRect(x: 80, y: 280, width: 160, height: 120)),
            (6, 480, 640, CGRect(x: 296, y: 88, width: 80, height: 80),
             CGRect(x: 80, y: 400, width: 120, height: 160)),
            (8, 480, 640, CGRect(x: 104, y: 472, width: 80, height: 80),
             CGRect(x: 280, y: 80, width: 120, height: 160))
        ]
        for (orientation, expectedWidth, expectedHeight, foreground, backdrop) in orientations {
            let orientedData = try fixture(orientation: orientation)
            let before = try raster(try await render(orientedData, enabled: false).jpegData)
            let after = try raster(try await render(orientedData).jpegData)
            try check(after.width == expectedWidth && after.height == expectedHeight,
                      "EXIF \(orientation) 的成片宽高正确")
            let blur = after.difference(from: before, in: backdrop)
            let sharpness = after.difference(from: before, in: foreground)
            print(String(format: "EXIF %d: background=%.4f, subject=%.4f", orientation, blur, sharpness))
            try check(blur > 1.5 && sharpness < 3,
                      "EXIF \(orientation) 的照片、深度和点按焦点对齐")
            let automatic = try raster(try await render(orientedData, focus: nil).jpegData)
            try check(automatic.difference(from: before, in: backdrop) > 1.5
                      && automatic.difference(from: before, in: foreground) < 3,
                      "EXIF \(orientation) 的自动近景选择与图像对齐")
        }

        let missing = try await render(data, hasDepth: false)
        try check(missing.outcome == .missingDepth, "拍照未交付深度时正确回退")
        let noAttachment = try await render(try fixture(embedsDepth: false))
        try check(noAttachment.outcome == .missingDepth, "文件缺少辅助深度时正确回退")
        let invalid = try await render(try fixture(constantDepth: true))
        try check(invalid.outcome == .invalidDepth, "平坦深度不能被报告为景深成功")
        let unsupported = try await render(data, requested: false)
        try check(unsupported.outcome == .unsupported, "不支持深度的相机保留普通照片")
        print("All depth rendering checks passed.")
    }

    static func main() async {
        do { try await run() }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
