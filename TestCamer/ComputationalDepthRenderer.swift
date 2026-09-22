// Shared native/monocular relative-disparity rendering. The caller supplies
// upright, zero-origin RGB plus a top-left depth raster with the same aspect.
// Disparity chooses the focal plane for every object, including every person.
import Foundation
import CoreImage
import CoreGraphics

/// Use on the processor/editor's serial rendering queue, as with DepthBlurRenderer.
final class ComputationalDepthRenderer {
    private let renderer: DepthBlurRenderer

    init(context: CIContext, colorSpace: CGColorSpace) {
        renderer = DepthBlurRenderer(context: context, colorSpace: colorSpace)
    }

    func render(original: CIImage, depth: DepthRaster, focus: NormalizedImagePoint,
                aperture: Float) throws -> DepthBlurOutput {
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
        let plan = try DepthMath.makePlan(depth: depth, focus: focus, isPerson: false, aperture: aperture)
        // This renderer already upsamples CoC with RGB edges, separates near/far
        // colors before blurring, and composites sharp pixels from the original.
        // A person matte must not make an out-of-focus person artificially sharp.
        let output = try renderer.render(original: original, plan: plan, protectedSubject: nil)
        return DepthBlurOutput(image: output.image, amountMask: output.amountMask,
            notes: "depthMode=computational relative disparity\n" + output.notes)
    }
}
