// DepthBlurRenderer.swift
// 拍后处理：真实视差 -> 清晰带 / 近景 / 远景 -> 连续半径虚化。
// 不使用人像抠图替代深度，不使用私有滤镜、自定义 Metal / CIKernel。
// 注意：这是可控的景深近似，不宣称复刻第三方 App 的私有光学渲染器。
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

struct DepthBlurOutput {
    let image: CIImage
    let amountMask: CIImage
    let notes: String
}

enum DepthRendererError: Error, LocalizedError {
    case imageCreation, filterUnavailable
    var errorDescription: String? {
        switch self {
        case .imageCreation: return "无法生成景深图像"
        case .filterUnavailable: return "当前环境无法执行所需原生图像滤镜"
        }
    }
}

/// 只在 DepthPhotoProcessor 的串行队列使用。
final class DepthBlurRenderer {
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private var usedUpsampleFallback = false
    private let workingLongEdge: CGFloat = 2048

    init(context: CIContext, colorSpace: CGColorSpace) {
        self.context = context; self.colorSpace = colorSpace
    }

    func render(original: CIImage, plan: DepthPlan, protectedSubject: CIImage? = nil) throws -> DepthBlurOutput {
        let full = original.extent
        guard !full.isEmpty, !full.isInfinite, !full.isNull else { throw DepthRendererError.imageCreation }
        let photoRatio = full.width/full.height
        let depthRatio = CGFloat(plan.width)/CGFloat(plan.height)
        guard abs(photoRatio/depthRatio-1) <= 0.02 else { throw DepthAnalysisError.alignmentMismatch }
        guard plan.nearFraction + plan.farFraction > 0.001 else { throw DepthAnalysisError.insufficientSeparation }

        // 只把“虚化层”限制到 2048 长边。最终清晰区域来自完整分辨率原图，不是放大缩略图。
        let scale = min(1, workingLongEdge/max(full.width, full.height))
        let w = max(1, Int((full.width*scale).rounded()))
        let h = max(1, Int((full.height*scale).rounded()))
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let working = original.transformed(by: CGAffineTransform(scaleX: CGFloat(w)/full.width,
                                                                 y: CGFloat(h)/full.height)).cropped(to: extent)
        let radius = plan.maxRadius(longEdge: Float(max(w, h)))
        let smallNear = try maskImage(values: plan.near, width: plan.width, height: plan.height)
        let smallFar = try maskImage(values: plan.far, width: plan.width, height: plan.height)
        // 人物 matte 只保护选中的主体；景深量仍来自本张真实视差。
        let protection = protectedSubject.map { resizedMask($0, to: extent) }
        let near = excludingSubject(upsample(smallNear, guide: working), protection: protection)
        let far = excludingSubject(upsample(smallFar, guide: working), protection: protection)
        let nearCoverage = coverage(near)
        let farCoverage = coverage(far)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        var result = working
        var affected = farCoverage

        if plan.farFraction > 0 {
            // 先排除近景/清晰物体，再模糊远景颜色；避免把人的肤色、白衣扩散进背景。
            let farOnly = try blend(working, over: clear, mask: farCoverage)
            let farBlur = try variableBlur(farOnly, amount: far, radius: radius, extent: extent)
            let normalizedFar = normalizeCoverage(farBlur, extent: extent)
            result = try blend(normalizedFar, over: result, mask: farCoverage)
        }
        if plan.nearFraction > 0 {
            // 粗深度不能可靠恢复被近景遮住的背景。限制在已知近景内虚化，
            // 不再按整圈散焦半径膨胀并大范围填色，避免桌沿/手臂附近的涂抹。
            let nearOnly = try blend(working, over: clear, mask: nearCoverage)
            let nearBlur = try variableBlur(nearOnly, amount: near, radius: radius, extent: extent)
            result = try blend(normalizeCoverage(nearBlur, extent: extent), over: result, mask: nearCoverage)
            affected = maximum(affected, nearCoverage).cropped(to: extent)
        }

        // 在小尺寸处分段物化，避免整个多层图像 DAG 在 12 MP 上同时展开。
        guard let smallCG = context.createCGImage(result, from: extent, format: .RGBA8, colorSpace: colorSpace),
              let affectedCG = context.createCGImage(affected, from: extent,
                                                     format: .RGBA8, colorSpace: nil) else {
            throw DepthRendererError.imageCreation
        }
        let scaledBlur = CIImage(cgImage: smallCG).transformed(by:
            CGAffineTransform(scaleX: full.width/CGFloat(smallCG.width), y: full.height/CGFloat(smallCG.height)))
        // 最后在完整分辨率再次扣除人物，防止上采样或邻层模糊侵入脸/手/发丝。
        let fullProtection = protectedSubject.map { resizedMask($0, to: full) }
        let fullAffected = excludingSubject(
            upsample(CIImage(cgImage: affectedCG, options: [.colorSpace: NSNull()]), guide: original),
            protection: fullProtection)
        let output = try blend(scaledBlur, over: original, mask: fullAffected).cropped(to: full)
        let amount = maximum(near, far).cropped(to: extent)
        let notes = String(format: "renderer=depth-controlled blur with conservative occlusion\nblurWorkingSize=%dx%d\nmaxRadiusAtOutput=%.2f px\nnearCoverage=%.1f%%\nfarCoverage=%.1f%%\nedgeUpsample=%@\nsharpSource=full-resolution original",
                           w, h, plan.maxRadius(longEdge: Float(max(full.width, full.height))),
                           plan.nearFraction*100, plan.farFraction*100,
                           usedUpsampleFallback ? "bilinear fallback" : "native edge-preserving")
        return DepthBlurOutput(image: output, amountMask: amount, notes: notes + "\nsubjectProtection=\(protectedSubject != nil)")
    }

    private func resizedMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let normalized = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX,
                                                                y: -mask.extent.minY))
        return clampedMask(normalized.transformed(by:
            CGAffineTransform(scaleX: extent.width/mask.extent.width, y: extent.height/mask.extent.height))
            .cropped(to: extent))
    }

    private func excludingSubject(_ mask: CIImage, protection: CIImage?) -> CIImage {
        guard let protection else { return mask }
        return mask.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: inverted(protection)
        ]).cropped(to: mask.extent)
    }

    /// 不创建带伽马的“深度图片”。0...1 CoC 作为线性数据送入图像滤镜。
    private func maskImage(values: [Float], width: Int, height: Int) throws -> CIImage {
        guard values.count == width*height else { throw DepthRendererError.imageCreation }
        let bytes = values.map { UInt8((min(1, max(0, $0.isFinite ? $0 : 0))*255).rounded()) }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw DepthRendererError.imageCreation
        }
        // CGImage 从第一行开始为顶部；与 DepthRaster 的 top-left 行序保持一致。
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    private func upsample(_ small: CIImage, guide: CIImage) -> CIImage {
        let filter = CIFilter.edgePreserveUpsample()
        filter.inputImage = guide
        filter.smallImage = small
        filter.spatialSigma = 3
        filter.lumaSigma = 0.12
        if let image = filter.outputImage {
            return clampedMask(image.cropped(to: guide.extent))
        }
        usedUpsampleFallback = true
        return clampedMask(small.transformed(by:
            CGAffineTransform(scaleX: guide.extent.width/small.extent.width,
                              y: guide.extent.height/small.extent.height)).cropped(to: guide.extent))
    }

    private func variableBlur(_ image: CIImage, amount: CIImage, radius: Float, extent: CGRect) throws -> CIImage {
        let filter = CIFilter.maskedVariableBlur()
        filter.inputImage = image.clampedToExtent()
        filter.mask = amount.clampedToExtent()
        filter.radius = radius
        guard let result = filter.outputImage else { throw DepthRendererError.filterUnavailable }
        return result.cropped(to: extent)
    }

    private func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) throws -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = foreground
        filter.backgroundImage = background
        filter.maskImage = mask
        guard let result = filter.outputImage else { throw DepthRendererError.filterUnavailable }
        return result.cropped(to: background.extent)
    }

    /// 模糊 premultiplied RGB 和 alpha 后再除以 alpha，避免遮挡边缘变黑。
    /// settingAlphaOne 只替换 alpha；这里必须先显式除以覆盖率。
    private func normalizeCoverage(_ image: CIImage, extent: CGRect) -> CIImage {
        image.unpremultiplyingAlpha().settingAlphaOne(in: extent).cropped(to: extent)
    }

    private func coverage(_ amount: CIImage) -> CIImage {
        clampedMask(amount.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 24, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 24, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 24, w: 0)
        ]))
    }

    private func clampedMask(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
    }
    private func inverted(_ image: CIImage) -> CIImage { image.applyingFilter("CIColorInvert") }
    private func maximum(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }
    private func alphaAsGray(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }
}
