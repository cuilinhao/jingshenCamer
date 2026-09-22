import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

struct PhotoEditingRenderResult: Sendable {
    let jpegData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let usedMetadataCompatibility: Bool
}

enum PhotoEditingRenderingError: Error, LocalizedError {
    case invalidRecipe, invalidPreviewSize, invalidImage, encodingFailed, focusUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRecipe: return "景深编辑参数无效，请重新选择焦点和光圈。"
        case .invalidPreviewSize: return "照片预览尺寸无效。"
        case .invalidImage: return "无法读取原始照片，请重新打开或拍摄。"
        case .encodingFailed: return "无法生成编辑后的照片，请重试。"
        case .focusUnavailable: return "所选位置缺少可靠深度，请点选物体内部的其他位置。"
        }
    }
}

/// Owns Core Image work on one background queue. Every render starts from the
/// immutable capture container plus cached depth, or legacy native auxiliary data.
/// No previous rendered result is cached or reused as an input image.
final class PhotoEditingRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.testcamer.photo-editing", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func render(sourceData: Data, recipe: PhotoEditRecipe,
                maximumDimension: Int? = nil, depthData: Data? = nil) async throws -> PhotoEditingRenderResult {
        guard recipe.isValid else { throw PhotoEditingRenderingError.invalidRecipe }
        guard maximumDimension.map({ $0 > 0 }) ?? true else {
            throw PhotoEditingRenderingError.invalidPreviewSize
        }
        return try await perform { [self] in
            if let depthData {
                return try renderCachedDepth(sourceData: sourceData, depthData: depthData,
                    recipe: recipe, maximumDimension: maximumDimension)
            }
            try validateFocus(sourceData: sourceData, sensorFocus: recipe.sensorFocus)
            let result = try AppleDepthRenderer(context: context).render(
                photoData: sourceData, aperture: recipe.aperture, sensorFocus: recipe.sensorFocus)
            let output = try encode(result.image, maximumDimension: maximumDimension,
                                    quality: maximumDimension == nil ? 0.95 : 0.9)
            return PhotoEditingRenderResult(jpegData: output.data, pixelWidth: output.width,
                pixelHeight: output.height, usedMetadataCompatibility: result.usedMetadataCompatibility)
        }
    }

    private func renderCachedDepth(sourceData: Data, depthData: Data, recipe: PhotoEditRecipe,
                                   maximumDimension: Int?) throws -> PhotoEditingRenderResult {
        let stored = try PhotoDepthData.decode(depthData)
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let raw = CIImage(data: sourceData, options: [.applyOrientationProperty: false]) else {
            throw PhotoEditingRenderingError.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let exif = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: exif) ?? .up
        let oriented = raw.oriented(orientation)
        let original = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.minX, y: -oriented.extent.minY))
        let depth = stored.raster.oriented(exif: orientation.rawValue)
        let sensorFocus = recipe.sensorFocus ?? NormalizedImagePoint(x: 0.5, y: 0.5)
        let focus = sensorFocus.oriented(exif: orientation.rawValue)
        guard depth.value(at: focus) != nil else { throw PhotoEditingRenderingError.focusUnavailable }
        let image: CIImage
        do {
            image = try ComputationalDepthRenderer(context: context, colorSpace: colorSpace)
                .render(original: original, depth: depth, focus: focus, aperture: recipe.aperture).image
        } catch DepthAnalysisError.insufficientSeparation {
            image = original
        }
        let output = try encode(image, maximumDimension: maximumDimension,
                                quality: maximumDimension == nil ? 0.95 : 0.9)
        return PhotoEditingRenderResult(jpegData: output.data, pixelWidth: output.width,
            pixelHeight: output.height, usedMetadataCompatibility: false)
    }

    /// A globally valid depth map can still contain holes. Never claim that a
    /// user's tapped object is in focus when its own depth sample is unavailable.
    /// This is read-only validation; Apple's filter still receives the untouched
    /// container and determines the focus plane using its native neighborhood.
    private func validateFocus(sourceData: Data, sensorFocus: NormalizedImagePoint?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let point = sensorFocus else { return }
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw AppleDepthRenderingError.invalidPhoto
        }
        let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
            ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth)
        guard let dictionary = auxiliary as? [AnyHashable: Any] else {
            throw AppleDepthRenderingError.missingDepth
        }
        let depth: AVDepthData
        do { depth = try AVDepthData(fromDictionaryRepresentation: dictionary) }
        catch { throw AppleDepthRenderingError.invalidDepth }
        let buffer = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32).depthDataMap
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, width <= Int.max / MemoryLayout<Float>.stride,
              rowBytes >= width * MemoryLayout<Float>.stride, rowBytes <= Int.max / height,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw AppleDepthRenderingError.invalidDepth
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AppleDepthRenderingError.invalidDepth }
        let x = min(width-1, Int(point.x*Double(width)))
        let y = min(height-1, Int(point.y*Double(height)))
        let value = base.advanced(by: y*rowBytes).assumingMemoryBound(to: Float.self)[x]
        guard value.isFinite, value > 0 else { throw PhotoEditingRenderingError.focusUnavailable }
    }

    func originalPreview(sourceData: Data, maximumDimension: Int = 1600) async throws -> Data {
        guard maximumDimension > 0 else { throw PhotoEditingRenderingError.invalidPreviewSize }
        return try await perform { [self] in
            guard let original = CIImage(data: sourceData, options: [.applyOrientationProperty: true]) else {
                throw PhotoEditingRenderingError.invalidImage
            }
            return try encode(original, maximumDimension: maximumDimension, quality: 0.9).data
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let value: T = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let result = autoreleasepool { () -> Result<T, Error> in
                    defer { context.clearCaches() }
                    return Result { try work() }
                }
                continuation.resume(with: result)
            }
        }
        try Task.checkCancellation()
        return value
    }

    private func encode(_ image: CIImage, maximumDimension: Int?, quality: Double)
        throws -> (data: Data, width: Int, height: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw PhotoEditingRenderingError.invalidImage
        }
        let scale = maximumDimension.map { min(1, CGFloat($0)/max(extent.width, extent.height)) } ?? 1
        let width = max(1, Int((extent.width*scale).rounded()))
        let height = max(1, Int((extent.height*scale).rounded()))
        let upright = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        // Keep scaling in the lazy Core Image graph before materializing pixels.
        // Focus/depth coordinates continue to refer to the full sensor container.
        let resized = upright.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width)/extent.width, y: CGFloat(height)/extent.height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let cg = context.createCGImage(resized, from: bounds, format: .RGBA8, colorSpace: colorSpace) else {
            throw PhotoEditingRenderingError.encodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoEditingRenderingError.encodingFailed
        }
        // Album exports intentionally contain only the flattened upright sRGB
        // photo. The editable source and recipe live separately in the app store.
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality,
                                         kCGImagePropertyOrientation: 1]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoEditingRenderingError.encodingFailed }
        return (data as Data, cg.width, cg.height)
    }
}
