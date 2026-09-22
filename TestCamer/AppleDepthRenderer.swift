import Foundation
import CoreImage
import ImageIO
import AVFoundation
import CoreVideo

struct AppleDepthOutput {
    let image: CIImage
    let notes: String
    let usedMetadataCompatibility: Bool
}

enum AppleDepthRenderingError: Error, LocalizedError {
    case invalidPhoto, missingDepth, invalidDepth, invalidAperture, invalidFocus
    case unavailable, invalidOutput

    var errorDescription: String? {
        switch self {
        case .invalidPhoto: return "原生照片容器无法读取"
        case .missingDepth: return "照片容器缺少原生深度附件，无法应用苹果景深"
        case .invalidDepth: return "照片的原生深度附件无效"
        case .invalidAperture: return "景深光圈参数无效"
        case .invalidFocus: return "所选焦点无效，请重新点选后拍摄"
        case .unavailable: return "当前系统无法创建苹果景深滤镜"
        case .invalidOutput: return "苹果景深滤镜未能生成有效图像"
        }
    }
}

/// Applies Apple's public depth renderer to the original, unblurred capture
/// container. Auxiliary mattes and calibration are supplied by Apple's factory.
final class AppleDepthRenderer {
    private let context: CIContext

    init(context: CIContext) { self.context = context }

    func render(photoData: Data, aperture: Float,
                sensorFocus: NormalizedImagePoint?) throws -> AppleDepthOutput {
        guard aperture.isFinite, aperture >= 1, aperture <= 22 else {
            throw AppleDepthRenderingError.invalidAperture
        }
        guard sensorFocus?.isValid != false else { throw AppleDepthRenderingError.invalidFocus }
        guard let source = CGImageSourceCreateWithData(photoData as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else {
            throw AppleDepthRenderingError.invalidPhoto
        }
        let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
            ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth)
        guard let dictionary = auxiliary as? [AnyHashable: Any] else {
            throw AppleDepthRenderingError.missingDepth
        }
        do {
            let depth = try AVDepthData(fromDictionaryRepresentation: dictionary)
            try validateDepthCoverage(depth)
        }
        catch { throw AppleDepthRenderingError.invalidDepth }
        guard let filter = context.depthBlurEffectFilter(forImageData: photoData, options: nil),
              filter.inputKeys.contains("inputAperture"), filter.inputKeys.contains("inputFocusRect"),
              let input = filter.value(forKey: kCIInputImageKey) as? CIImage,
              filter.value(forKey: kCIInputDisparityImageKey) is CIImage else {
            throw AppleDepthRenderingError.unavailable
        }
        filter.setValue(aperture, forKey: "inputAperture")
        if let point = sensorFocus {
            // The container factory retains sensor orientation. Focus rectangles
            // are normalized in that image with a bottom-left origin. Do not
            // rotate the tap before supplying it here; rotate the output once.
            let size: CGFloat = 0.02
            let x = min(1-size, max(0, CGFloat(point.x)-size/2))
            let y = min(1-size, max(0, 1-CGFloat(point.y)-size/2))
            filter.setValue(CIVector(cgRect: CGRect(x: x, y: y, width: size, height: size)),
                            forKey: "inputFocusRect")
        }
        guard var output = filter.outputImage else { throw AppleDepthRenderingError.invalidOutput }
        var usedMetadataCompatibility = false
        // Some macOS runtimes return the exact input object when the native
        // auxiliary metadata path is unsupported. Identity proves a no-op; do
        // not infer this from a low-contrast preview or a small pixel sample.
        // Retry only that proven bypass, keeping the same Apple filter, actual
        // disparity values, calibration, and portrait/hair/glasses images.
        if output === input, filter.inputKeys.contains("inputAuxDataMetadata"),
           let disparity = filter.value(forKey: kCIInputDisparityImageKey) as? CIImage {
            var disparityProperties = disparity.properties
            let inheritedMetadata = disparityProperties.removeValue(forKey: kCGImageAuxiliaryDataInfoMetadata as String)
            if filter.value(forKey: "inputAuxDataMetadata") != nil || inheritedMetadata != nil {
                filter.setValue(nil, forKey: "inputAuxDataMetadata")
                filter.setValue(disparity.settingProperties(disparityProperties), forKey: kCIInputDisparityImageKey)
                guard let retried = filter.outputImage else { throw AppleDepthRenderingError.invalidOutput }
                output = retried
                usedMetadataCompatibility = true
            }
        }
        guard output.extent == input.extent,
              output.extent.width.isFinite, output.extent.height.isFinite,
              output.extent.width > 0, output.extent.height > 0 else {
            throw AppleDepthRenderingError.invalidOutput
        }
        let rawOrientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1
        let upright = output.oriented(forExifOrientation: Int32(orientation))
        let notes = usedMetadataCompatibility
            ? "苹果景深（兼容）：系统原生元数据路径直接返回原图；已使用同一苹果滤镜的兼容路径，保留真实深度、校准及可用辅助遮罩。兼容路径未使用辅助深度元数据，效果仍需像素检测。"
            : "苹果公开景深渲染，使用照片中的原生深度、元数据与可用辅助附件"
        return AppleDepthOutput(image: upright, notes: notes, usedMetadataCompatibility: usedMetadataCompatibility)
    }

    /// Inspect a converted, read-only view; never replace or repair the native
    /// data delivered to Apple's filter. A constant positive plane is valid.
    private func validateDepthCoverage(_ depth: AVDepthData) throws {
        let map = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32).depthDataMap
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard width > 0, height > 0,
              width <= Int.max / height,
              width <= Int.max / MemoryLayout<Float>.stride,
              rowBytes >= width * MemoryLayout<Float>.stride,
              rowBytes <= Int.max / height,
              CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DisparityFloat32,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else {
            throw AppleDepthRenderingError.invalidDepth
        }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { throw AppleDepthRenderingError.invalidDepth }
        var valid = 0
        for y in 0..<height {
            let row = base.advanced(by: y*rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width where row[x].isFinite && row[x] > 0 { valid += 1 }
        }
        guard Double(valid) / Double(width*height) >= 0.25 else {
            throw AppleDepthRenderingError.invalidDepth
        }
    }

}
