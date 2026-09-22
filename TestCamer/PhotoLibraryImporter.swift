import Foundation
import ImageIO
@preconcurrency import AVFoundation

struct ImportedEditablePhoto: Sendable {
    let document: EditablePhotoDocument
    let originalPreviewData: Data
}

enum PhotoLibraryImportError: Error, LocalizedError, Equatable {
    case invalidImage, processingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "照片导入失败：无法读取所选图片，请选择其他照片。"
        case .processingFailed: return "照片导入失败：无法生成可编辑景深，请重试或选择其他照片。"
        }
    }
}

final class PhotoLibraryImporter: Sendable {
    private let decodingQueue = DispatchQueue(label: "com.testcamer.photo-import", qos: .userInitiated)
    private let processor: DepthPhotoProcessor

    init(processor: DepthPhotoProcessor = DepthPhotoProcessor()) {
        self.processor = processor
    }

    func prepare(data: Data) async throws -> ImportedEditablePhoto {
        try Task.checkCancellation()
        let photo: CapturedPhoto = try await withCheckedThrowingContinuation { continuation in
            decodingQueue.async {
                let result = autoreleasepool { Result { try Self.capture(from: data) } }
                continuation.resume(with: result)
            }
        }
        try Task.checkCancellation()
        let processed: ProcessedPhoto
        do { processed = try await processor.process(photo) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PhotoLibraryImportError.processingFailed }
        try Task.checkCancellation()
        // 拍摄允许景深失败时退回普通照片；导入可编辑列表则必须得到真实可编辑结果。
        guard let recipe = processed.editRecipe, recipe.isValid else {
            throw PhotoLibraryImportError.processingFailed
        }
        let now = Date()
        let document = EditablePhotoDocument(createdAt: now, updatedAt: now, sourceData: data,
            initialRecipe: recipe, recipe: recipe, previewData: processed.previewData,
            depthData: processed.editDepthData,
            renderingInfo: PhotoRenderingInfo(appleFallbackReason: processed.appleFallbackReason,
                usedAppleMetadataCompatibility: processed.usedAppleMetadataCompatibility))
        return ImportedEditablePhoto(document: document, originalPreviewData: processed.originalPreviewData)
    }

    /// 只在后台读取图片与附件。原始容器和 EXIF 保持不变，由现有处理器统一处理方向。
    private static func capture(from data: Data) throws -> CapturedPhoto {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width > 0, image.height > 0 else {
            throw PhotoLibraryImportError.invalidImage
        }
        var native: NativeDepthSnapshot?
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            guard let dictionary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type)
                as? [AnyHashable: Any] else { continue }
            if let snapshot = try? NativeDepthSnapshot(
                depthData: AVDepthData(fromDictionaryRepresentation: dictionary)) {
                native = snapshot
                break
            }
        }
        return CapturedPhoto(data: data, depthRequested: native != nil, hasDepthData: native != nil,
            nativeDepth: native, options: DepthOptions(enabled: true, aperture: 1.4),
            transientDeviceFocus: nil, captureSummary: "source=system photo library",
            prefersAppleDepth: native != nil)
    }
}
