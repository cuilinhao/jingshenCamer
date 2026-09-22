// 本地人工验收工具：重放同一次快门的原图和 AVDepthData，不把附件写入最终照片。
import Foundation
import ImageIO
import AVFoundation

@main
struct DepthPhotoReplay {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            print("Usage: replay <original.heic> <same-frame-with-depth.heic> <output-directory> [aperture] [sensor-focus-x sensor-focus-y]")
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
        let f = args.count > 4 ? Float(args[4]) ?? 1.8 : 1.8
        let focus: NormalizedImagePoint? = args.count > 6
            ? NormalizedImagePoint(x: Double(args[5])!, y: Double(args[6])!) : nil
        let result = try await DepthPhotoProcessor().process(CapturedPhoto(data: original,
            depthRequested: true, hasDepthData: true, nativeDepth: NativeDepthSnapshot(depthData: depth),
            options: DepthOptions(enabled: true, aperture: f), transientDeviceFocus: focus,
            captureSummary: "offline replay of a real same-frame camera capture", nativePortraitMatte: nativeMatte))
        let folder = URL(fileURLWithPath: args[3], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try result.jpegData.write(to: folder.appendingPathComponent("rendered.jpg"))
        try result.originalPreviewData.write(to: folder.appendingPathComponent("original.jpg"))
        try result.diagnosticMaskData?.write(to: folder.appendingPathComponent("mask.jpg"))
        try result.diagnosticText.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
