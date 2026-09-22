import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Main-actor owner drives this value state; expensive rendering never owns UI state.
struct PhotoEditingSession {
    struct Request: Equatable {
        let revision: UInt64
        let recipe: PhotoEditRecipe
    }

    private(set) var desiredRecipe: PhotoEditRecipe
    private(set) var displayedRecipe: PhotoEditRecipe
    private var revision: UInt64 = 0
    private var renderedRevision: UInt64 = 0
    private var active: Request?
    private var invalidated = false

    init(recipe: PhotoEditRecipe) {
        desiredRecipe = recipe
        displayedRecipe = recipe
    }

    var isSettled: Bool { !invalidated && active == nil && revision == renderedRevision }

    mutating func select(_ recipe: PhotoEditRecipe) {
        guard !invalidated, recipe.isValid, recipe != desiredRecipe else { return }
        desiredRecipe = recipe
        revision &+= 1
    }

    mutating func beginNext() -> Request? {
        guard !invalidated, active == nil, revision != renderedRevision else { return nil }
        let request = Request(revision: revision, recipe: desiredRecipe)
        active = request
        return request
    }

    /// A stale completion clears its work slot but cannot change the displayed image.
    @discardableResult
    mutating func complete(_ request: Request, succeeded: Bool) -> Bool {
        guard !invalidated, active == request else { return false }
        active = nil
        guard request.revision == revision else { return false }
        if succeeded { displayedRecipe = request.recipe }
        else { desiredRecipe = displayedRecipe }
        renderedRevision = revision
        return true
    }

    mutating func invalidate() {
        invalidated = true
        active = nil
    }
}

/// UIKit uses a top-left origin. The renderer takes raw sensor coordinates;
/// mirrored and rotated photographs need the inverse EXIF transform exactly once.
enum PhotoEditGeometry {
    static func imageRect(viewSize: CGSize, imageSize: CGSize) -> CGRect? {
        guard viewSize.width.isFinite, viewSize.height.isFinite,
              imageSize.width.isFinite, imageSize.height.isFinite,
              viewSize.width > 0, viewSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (viewSize.width-size.width)/2, y: (viewSize.height-size.height)/2,
                      width: size.width, height: size.height)
    }

    static func sensorPoint(at point: CGPoint, viewSize: CGSize, imageSize: CGSize,
                            exif: UInt32) -> NormalizedImagePoint? {
        guard point.x.isFinite, point.y.isFinite, (1...8).contains(exif),
              let rect = imageRect(viewSize: viewSize, imageSize: imageSize),
              rect.contains(point) else { return nil }
        let upright = NormalizedImagePoint(x: Double((point.x-rect.minX)/rect.width),
                                           y: Double((point.y-rect.minY)/rect.height))
        let inverse: UInt32 = exif == 6 ? 8 : (exif == 8 ? 6 : exif)
        return upright.oriented(exif: inverse)
    }

    static func displayPoint(sensorPoint: NormalizedImagePoint, viewSize: CGSize,
                             imageSize: CGSize, exif: UInt32) -> CGPoint? {
        guard sensorPoint.isValid, (1...8).contains(exif),
              let rect = imageRect(viewSize: viewSize, imageSize: imageSize) else { return nil }
        let point = sensorPoint.oriented(exif: exif)
        return CGPoint(x: rect.minX + CGFloat(point.x)*rect.width, y: rect.minY + CGFloat(point.y)*rect.height)
    }
}
