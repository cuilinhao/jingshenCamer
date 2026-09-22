// 本地人工验收工具：重放同一次快门的原图和 AVDepthData，不把附件写入最终照片。
import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

@main
struct DepthPhotoReplay {
    static func main() async throws {
        let args = CommandLine.arguments
        guard [4, 5, 7].contains(args.count) else {
            print("Usage: replay <unblurred-original.heic> <same-frame-with-depth.heic> <output-directory> [aperture] [sensor-focus-x sensor-focus-y]")
            print("The RGB input must be unblurred. Reprocessing an already blurred system Portrait photo is NOT a valid quality comparison.")
            exit(2)
        }
        let original = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let auxiliary = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        guard let source = CGImageSourceCreateWithData(auxiliary as CFData, nil),
              let dictionary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
                ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth) else {
            throw DepthAnalysisError.insufficientDepth
        }
        let depth = try AVDepthData(fromDictionaryRepresentation: dictionary as! [AnyHashable: Any])
        let nativeMatte: NativePortraitMatteSnapshot?
        if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypePortraitEffectsMatte),
           let matte = try? AVPortraitEffectsMatte(fromDictionaryRepresentation: info as! [AnyHashable: Any]) {
            nativeMatte = try NativePortraitMatteSnapshot(portraitEffectsMatte: matte)
        } else { nativeMatte = nil }
        let f: Float
        if args.count > 4 {
            guard let value = Float(args[4]), value.isFinite, (1.4...16).contains(value) else {
                throw replayError("光圈必须为 1.4～16 的有限数值")
            }
            f = value
        } else { f = 1.4 }
        let focus: NormalizedImagePoint?
        if args.count > 5 {
            guard args.count == 7, let x = Double(args[5]), let y = Double(args[6]),
                  NormalizedImagePoint(x: x, y: y).isValid else {
                throw replayError("焦点须同时提供 x 和 y，范围为 0～1")
            }
            focus = NormalizedImagePoint(x: x, y: y)
        } else { focus = nil }
        let input = try combining(original: original, auxiliary: auxiliary)
        let photo = CapturedPhoto(data: input,
            depthRequested: true, hasDepthData: true, nativeDepth: try NativeDepthSnapshot(depthData: depth),
            options: DepthOptions(enabled: true, aperture: f), transientDeviceFocus: focus,
            captureSummary: "offline replay; caller must supply unblurred same-frame RGB and native depth",
            nativePortraitMatte: nativeMatte)
        let processor = DepthPhotoProcessor()
        let result = try await processor.process(photo)
        let legacy = try await processor.process(photo, renderer: .legacy)
        let folder = URL(fileURLWithPath: args[3], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try result.jpegData.write(to: folder.appendingPathComponent("rendered.jpg"))
        try legacy.jpegData.write(to: folder.appendingPathComponent("legacy.jpg"))
        try result.originalPreviewData.write(to: folder.appendingPathComponent("original.jpg"))
        try result.diagnosticMaskData?.write(to: folder.appendingPathComponent("difference.jpg"))
        let report = "APPLE\n" + result.diagnosticText + "\n\nLEGACY\n" + legacy.diagnosticText
            + "\n\nQuality validation requires an unblurred source; a pre-rendered Portrait reference cannot prove equivalence.\n"
        try report.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print("Apple: \(result.outcome.rawValue); legacy: \(legacy.outcome.rawValue). Outputs: \(folder.path)")
    }

    // 同一个文件时完全保留相机容器。分离素材只在尺寸和方向一致时合并；
    // 调用者仍需保证确属同一次快门，不能用另一张照片的深度来验收。
    static func combining(original: Data, auxiliary: Data) throws -> Data {
        if original == auxiliary { return original }
        guard let rgb = CGImageSourceCreateWithData(original as CFData, nil),
              let aux = CGImageSourceCreateWithData(auxiliary as CFData, nil),
              let rgbProperties = CGImageSourceCopyPropertiesAtIndex(rgb, 0, nil) as? [String: Any],
              let auxProperties = CGImageSourceCopyPropertiesAtIndex(aux, 0, nil) as? [String: Any] else {
            throw replayError("无法读取同帧素材")
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] {
            guard (rgbProperties[key as String] as? NSNumber) == (auxProperties[key as String] as? NSNumber) else {
                throw replayError("原图与辅助容器的尺寸或方向不一致")
            }
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
            UTType.heic.identifier as CFString, 1, nil) else { throw replayError("无法创建内存 HEIC") }
        CGImageDestinationAddImageFromSource(destination, rgb, 0, nil)
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth,
                     kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
                     kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(aux, 0, type) {
                CGImageDestinationAddAuxiliaryDataInfo(destination, type, info)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw replayError("合并原生附件失败") }
        return data as Data
    }

    static func replayError(_ message: String) -> NSError {
        NSError(domain: "DepthPhotoReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
