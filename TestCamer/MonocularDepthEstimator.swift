import Foundation
import CoreImage
import CoreML
import CoreVideo

enum MonocularDepthError: Error, LocalizedError {
    case invalidImage, modelNotBundled, incompatibleModel, inputAllocation, invalidOutput
    case modelLoading(String), prediction(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "照片尺寸无效，无法估计智能景深"
        case .modelNotBundled: return "应用内缺少智能景深模型，已保留原图"
        case .incompatibleModel: return "智能景深模型接口不兼容，已保留原图"
        case .inputAllocation: return "无法创建智能景深输入，已保留原图"
        case .invalidOutput: return "智能景深模型返回无效深度，已保留原图"
        case .modelLoading(let reason): return "智能景深模型加载失败：\(reason)"
        case .prediction(let reason): return "智能景深估计失败：\(reason)"
        }
    }
}

/// Synchronous, offline inference. The owner calls this on its background serial queue;
/// creating the estimator does not load the model or perform inference.
final class MonocularDepthEstimator {
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var cachedModel: MLModel?

    init(context: CIContext) { self.context = context }

    /// Input is upright with zero origin. Output uses top-left rows and relative
    /// disparity (larger = nearer), never metric distance or hardware depth.
    func estimate(image: CIImage) throws -> DepthRaster {
        try autoreleasepool {
            try Self.validate(image)
            let model = try loadModel()
            let buffer = try inputBuffer(for: image, width: 518, height: 392)
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
            let prediction: MLFeatureProvider
            do { prediction = try model.prediction(from: input) }
            catch { throw MonocularDepthError.prediction(error.localizedDescription) }
            guard let depth = prediction.featureValue(for: "depth")?.imageBufferValue,
                  CVPixelBufferGetWidth(depth) == 518, CVPixelBufferGetHeight(depth) == 392 else {
                throw MonocularDepthError.invalidOutput
            }
            return try MonocularDepthConversion.raster(depth, imageSize: image.extent.size)
        }
    }

    private func loadModel() throws -> MLModel {
        if let cachedModel { return cachedModel }
        let name = "DepthAnythingV2SmallF16"
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models") else {
            throw MonocularDepthError.modelNotBundled
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model: MLModel
        do { model = try MLModel(contentsOf: url, configuration: configuration) }
        catch { throw MonocularDepthError.modelLoading(error.localizedDescription) }
        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName["image"]?.imageConstraint,
              let output = description.outputDescriptionsByName["depth"]?.imageConstraint,
              input.pixelsWide == 518, input.pixelsHigh == 392,
              input.pixelFormatType == kCVPixelFormatType_32BGRA,
              output.pixelsWide == 518, output.pixelsHigh == 392,
              output.pixelFormatType == kCVPixelFormatType_OneComponent16Half else {
            throw MonocularDepthError.incompatibleModel
        }
        cachedModel = model
        return model
    }

    private static func validate(_ image: CIImage) throws {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              extent.origin == .zero, extent.width.isFinite, extent.height.isFinite else {
            throw MonocularDepthError.invalidImage
        }
    }

    /// Stretch the entire upright image to the fixed model input, without a crop.
    /// Core Image writes the top of the image to the first CVPixelBuffer row.
    func inputBuffer(for image: CIImage, width: Int, height: Int) throws -> CVPixelBuffer {
        try Self.validate(image)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else {
            throw MonocularDepthError.inputAllocation
        }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                        kCVPixelBufferCGImageCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw MonocularDepthError.inputAllocation }
        // Clamp before interpolation so the first/last pixels do not blend with
        // transparent space outside the photo and create an artificial dark border.
        let scaled = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                                              y: CGFloat(height) / image.extent.height))
        context.render(scaled, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: colorSpace)
        return buffer
    }
}

enum MonocularDepthConversion {
    /// Apple's artifact normalizes ReLU disparity by its maximum. Preserve its
    /// scale and ordering; add a fixed epsilon so valid zero (far) is not confused
    /// with missing hardware depth. Do not stretch tiny/constant ranges into blur.
    static func raster(_ buffer: CVPixelBuffer, imageSize: CGSize) throws -> DepthRaster {
        let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= 4096, sourceHeight <= 4096,
              !CVPixelBufferIsPlanar(buffer),
              format == kCVPixelFormatType_OneComponent16Half || format == kCVPixelFormatType_OneComponent32Float else {
            throw MonocularDepthError.invalidOutput
        }
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { throw MonocularDepthError.invalidImage }
        let aspect = Double(imageSize.width / imageSize.height)
        guard aspect.isFinite, aspect > 0 else { throw MonocularDepthError.invalidImage }
        let edge = Double(max(sourceWidth, sourceHeight))
        let width = max(1, Int((edge * min(1, aspect)).rounded()))
        let height = max(1, Int((edge / max(1, aspect)).rounded()))
        guard abs(Double(width) / Double(height) / aspect - 1) <= 0.02 else {
            throw DepthAnalysisError.alignmentMismatch
        }

        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw MonocularDepthError.invalidOutput
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerSample = format == kCVPixelFormatType_OneComponent16Half ? 2 : 4
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), stride >= sourceWidth * bytesPerSample else {
            throw MonocularDepthError.invalidOutput
        }
        var samples = [Float](repeating: 0, count: sourceWidth * sourceHeight)
        for y in 0..<sourceHeight {
            let row = base.advanced(by: y * stride)
            for x in 0..<sourceWidth {
                let value: Float
                if bytesPerSample == 2 {
                    value = Float(Float16(bitPattern: row.assumingMemoryBound(to: UInt16.self)[x]))
                } else {
                    value = row.assumingMemoryBound(to: Float.self)[x]
                }
                guard value.isFinite, value >= 0 else { throw MonocularDepthError.invalidOutput }
                samples[y * sourceWidth + x] = value
            }
        }

        // Pixel-center bilinear resampling reverses the full-image stretch. Rows
        // stay top-left throughout; neither a vertical flip nor a center crop belongs here.
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = min(Double(sourceHeight - 1), max(0, (Double(y) + 0.5) * Double(sourceHeight) / Double(height) - 0.5))
            let y0 = Int(sy), y1 = min(sourceHeight - 1, y0 + 1), fy = Float(sy - Double(y0))
            for x in 0..<width {
                let sx = min(Double(sourceWidth - 1), max(0, (Double(x) + 0.5) * Double(sourceWidth) / Double(width) - 0.5))
                let x0 = Int(sx), x1 = min(sourceWidth - 1, x0 + 1), fx = Float(sx - Double(x0))
                let top = samples[y0 * sourceWidth + x0] * (1 - fx) + samples[y0 * sourceWidth + x1] * fx
                let bottom = samples[y1 * sourceWidth + x0] * (1 - fx) + samples[y1 * sourceWidth + x1] * fx
                let value = top * (1 - fy) + bottom * fy + 0.001
                guard value.isFinite, value > 0 else { throw MonocularDepthError.invalidOutput }
                values[y * width + x] = value
            }
        }
        return try DepthRaster(width: width, height: height, values: values)
    }
}
