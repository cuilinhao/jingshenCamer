// Shared native/monocular relative-disparity rendering. The caller supplies
// upright, zero-origin RGB plus a top-left depth raster with the same aspect.
// Disparity chooses focus; a selected person's reliable depth spread and face
// can conservatively extend its clear interval.
import Foundation
import CoreImage
import CoreGraphics

/// Use on the processor/editor's serial rendering queue, as with DepthBlurRenderer.
final class ComputationalDepthRenderer {
    private let renderer: DepthBlurRenderer
    private let context: CIContext

    init(context: CIContext, colorSpace: CGColorSpace) {
        self.context = context
        renderer = DepthBlurRenderer(context: context, colorSpace: colorSpace)
    }

    func render(original: CIImage, depth: DepthRaster, focus: NormalizedImagePoint,
                aperture: Float, selectedSubject: CIImage? = nil,
                selectedSubjectFace: NormalizedImagePoint? = nil) throws -> DepthBlurOutput {
        let extent = original.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              extent.origin == .zero, extent.width.isFinite, extent.height.isFinite else {
            throw DepthRendererError.imageCreation
        }
        guard focus.isValid else { throw DepthAnalysisError.focusUnavailable }
        guard abs((extent.width/extent.height)/(CGFloat(depth.width)/CGFloat(depth.height))-1) <= 0.02 else {
            throw DepthAnalysisError.alignmentMismatch
        }
        // Flat/sparse depth and unavailable focus throw before image processing;
        // callers can preserve the ordinary photo instead of inventing depth.
        let confidence = try selectedSubject.map { try subjectConfidence($0, depth: depth) }
        let plan = try DepthMath.makePlan(depth: depth, focus: focus, isPerson: false, aperture: aperture,
                                         selectedSubjectConfidence: confidence,
                                         selectedSubjectFace: selectedSubjectFace)
        // This renderer already upsamples CoC with RGB edges, separates near/far
        // colors before blurring, and composites sharp pixels from the original.
        // Coarse-depth upsampling can mix background coverage into a small face
        // even when its planned CoC is zero. Preserve only that already-clear,
        // high-confidence core at full RGB resolution; out-of-focus limbs and
        // unknown depths never gain sharp eligibility from the person matte.
        let sharpCore: CIImage?
        if plan.subjectFocusRange != nil, let selectedSubject, let confidence {
            sharpCore = try qualifiedSharpCore(mask: selectedSubject, confidence: confidence,
                                               depth: depth, plan: plan, extent: extent)
        } else { sharpCore = nil }
        let output = try renderer.render(original: original, plan: plan, protectedSubject: sharpCore)
        return DepthBlurOutput(image: output.image, amountMask: output.amountMask,
            notes: "depthMode=computational relative disparity\nadaptiveSubjectFocus=\(plan.subjectFocusRange != nil)\nqualifiedSharpCore=\(sharpCore != nil)\n" + output.notes)
    }

    private func qualifiedSharpCore(mask: CIImage, confidence: [Float], depth: DepthRaster,
                                     plan: DepthPlan, extent: CGRect) throws -> CIImage {
        let eligible: [UInt8] = depth.values.indices.map { i in
            let d = depth.values[i]
            return d.isFinite && d > 0 && confidence[i] >= 0.9
                && plan.near[i] == 0 && plan.far[i] == 0 ? 255 : 0
        }
        guard let provider = CGDataProvider(data: Data(eligible) as CFData),
              let cg = CGImage(width: depth.width, height: depth.height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: depth.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw DepthRendererError.imageCreation
        }
        let qualification = CIImage(cgImage: cg, options: [.colorSpace: NSNull(), .nearestSampling: true])
            .transformed(by: CGAffineTransform(scaleX: extent.width/CGFloat(depth.width),
                                               y: extent.height/CGFloat(depth.height)))
        let alignedSubject = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX,
                                                                   y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width/mask.extent.width,
                                               y: extent.height/mask.extent.height))
        // Low-confidence contours receive no extra original-pixel protection.
        let reliableSubject = alignedSubject.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 10, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 10, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 10, w: 0),
            "inputBiasVector": CIVector(x: -9, y: -9, z: -9, w: 0)
        ]).applyingFilter("CIColorClamp")
        return qualification.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: reliableSubject
        ]).cropped(to: extent)
    }

    private func subjectConfidence(_ mask: CIImage, depth: DepthRaster) throws -> [Float] {
        let extent = mask.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              extent.width.isFinite, extent.height.isFinite,
              abs((extent.width/extent.height)/(CGFloat(depth.width)/CGFloat(depth.height))-1) <= 0.02 else {
            throw DepthAnalysisError.alignmentMismatch
        }
        let small = mask.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(depth.width)/extent.width,
                                               y: CGFloat(depth.height)/extent.height))
        // CGImage data is top-left, matching DepthRaster. Keeping mask values
        // untagged avoids applying the photo's sRGB gamma to confidence values.
        guard let cg = context.createCGImage(small,
            from: CGRect(x: 0, y: 0, width: depth.width, height: depth.height),
            format: .RGBA8, colorSpace: nil), let data = cg.dataProvider?.data else {
            throw DepthRendererError.imageCreation
        }
        let bytes = data as Data
        return (0..<depth.height).flatMap { y in
            (0..<depth.width).map { x in Float(bytes[y*cg.bytesPerRow+x*4])/255 }
        }
    }
}
