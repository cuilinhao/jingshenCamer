//
//  DepthPhotoProcessor.swift
//  TestCamer
//
//  仅在快门拍摄完成后调用。纯 Swift + Apple 原生 Core Image / Image I/O。
//  不做实时渲染，不用人像抠图冒充深度，不保存可重编辑的焦点/深度/Recipe。
//

import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

struct ProcessedPhoto: Sendable {
    /// 唯一允许保存到相册的文件：已经烘焙效果、移除辅助深度及相机私有元数据的普通 JPEG。
    let jpegData: Data
    /// 仅供本次结果页显示；重拍即释放，不是可重编辑原片档案。
    let previewData: Data
    let originalPreviewData: Data
    let outcome: DepthRenderOutcome
    let aperture: Float
    let pixelWidth: Int
    let pixelHeight: Int
}

/// CIContext 和处理工作只在 renderQueue 上使用，不阻塞主线程。
final class DepthPhotoProcessor: @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "com.testcamer.photo-depth", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func process(_ photo: CapturedPhoto) async throws -> ProcessedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                let result: Result<ProcessedPhoto, Error> = autoreleasepool {
                    Result { try render(photo) }
                }
                continuation.resume(with: result)
            }
        }
    }

    private func render(_ photo: CapturedPhoto) throws -> ProcessedPhoto {
        dispatchPrecondition(condition: .onQueue(renderQueue))
        let started = Date()
        defer { context.clearCaches() }
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let rawImage = CIImage(data: photo.data, options: [.applyOrientationProperty: false]) else {
            throw CameraError.captureFailed
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientationValue = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up

        // RGB 与深度都先应用同一个 EXIF 方向，然后给景深工厂传 .up，避免双重旋转。
        // 不把低分辨率 depthMap 当作一张普通 sRGB 灰度图来重新归一化。
        var uprightProperties = rawImage.properties
        uprightProperties[kCGImagePropertyOrientation as String] = 1
        let original = normalizedOrigin(rawImage.oriented(orientation)).settingProperties(uprightProperties)
        guard !original.extent.isEmpty, !original.extent.isInfinite else { throw CameraError.captureFailed }

        var outcome: DepthRenderOutcome
        var renderedCGImage: CGImage?
        if !photo.options.enabled {
            outcome = .disabled
        } else if !photo.depthRequested {
            outcome = .unsupported
        } else if !photo.hasDepthData {
            outcome = .missingDepth
        } else if let capturedDepth = depthData(from: source) {
            let disparityData = capturedDepth.applyingExifOrientation(orientation)
                .converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            if !hasUsableDepth(disparityData.depthDataMap) {
                outcome = .invalidDepth
            } else if let disparity = CIImage(depthData: disparityData),
                      let filter = context.depthBlurEffectFilter(
                        for: original,
                        disparityImage: disparity,
                        portraitEffectsMatte: portraitMatte(from: source, orientation: orientation),
                        orientation: .up,
                        options: nil),
                      filter.inputKeys.contains("inputAperture") {
                // 工厂会准备原生景深需要的辅助信息；不要再 setDefaults() 把这些信息清空。
                // 本版不覆盖焦点矩形：使用系统自动景深选择。保留原 Demo 的硬件点按对焦，
                // 但不承诺“点击位置 = 自定义算法焦平面”，也不实现拍后重新对焦。
                filter.setValue(NSNumber(value: photo.options.aperture), forKey: "inputAperture")
                print("[Depth] using native depth blur, virtual f/\(photo.options.aperture)")
                if let rendered = filter.outputImage {
                    renderedCGImage = context.createCGImage(rendered.cropped(to: original.extent),
                                                            from: original.extent,
                                                            format: .RGBA8, colorSpace: colorSpace)
                }
                outcome = renderedCGImage == nil ? .renderFailed : .applied
            } else {
                outcome = .renderFailed
            }
        } else {
            outcome = .missingDepth
        }

        // 所有缺深度/无效深度/滤镜失败路径都保留普通照片，明确标注 fallback。
        // 不悄悄改成全图模糊，也不伪造一次“景深成功”。
        if renderedCGImage == nil {
            print("[Depth] fallback: \(outcome.rawValue)")
            renderedCGImage = context.createCGImage(original, from: original.extent,
                                                    format: .RGBA8, colorSpace: colorSpace)
        }
        guard let cgImage = renderedCGImage else { throw CameraError.captureFailed }
        let jpeg = try encodeJPEG(cgImage, quality: 0.95)
        let preview = try previewJPEG(CIImage(cgImage: cgImage))
        let before = outcome.isDepthApplied ? try previewJPEG(original) : preview
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "[Depth] outcome=%@, image=%dx%d, elapsed=%.2fs, JPEG=%d bytes",
                     outcome.rawValue, cgImage.width, cgImage.height, elapsed, jpeg.count))
        return ProcessedPhoto(jpegData: jpeg, previewData: preview, originalPreviewData: before,
                              outcome: outcome, aperture: photo.options.aperture,
                              pixelWidth: cgImage.width, pixelHeight: cgImage.height)
    }

    private func depthData(from source: CGImageSource) -> AVDepthData? {
        // 同一次拍照的内存文件中读取，绝不混用另一帧的实时深度。
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            if let dictionary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any],
               let depth = try? AVDepthData(fromDictionaryRepresentation: dictionary) {
                return depth
            }
        }
        return nil
    }

    private func portraitMatte(from source: CGImageSource, orientation: CGImagePropertyOrientation) -> CIImage? {
        // 人像时可选的边缘辅助；杯子/植物场景没有 matte 也照常使用真实深度。
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0,
                  kCGImageAuxiliaryDataTypePortraitEffectsMatte) as? [AnyHashable: Any],
              let matte = try? AVPortraitEffectsMatte(fromDictionaryRepresentation: info) else { return nil }
        return CIImage(cvPixelBuffer: matte.applyingExifOrientation(orientation).mattingImage)
    }

    private func hasUsableDepth(_ map: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DisparityFloat32,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return false }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        var total = 0
        var valid = 0
        var minimum = Float.infinity
        var maximum = -Float.infinity
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in stride(from: 0, to: width, by: max(1, width / 64)) {
                total += 1
                let value = row[x]
                if value.isFinite && value > 0 {
                    valid += 1
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                }
            }
        }
        print("[Depth] disparity=\(width)x\(height), valid=\(valid)/\(total), range=\(minimum)...\(maximum)")
        return DepthCapturePolicy.usableDepth(valid: valid, total: total, minimum: minimum, maximum: maximum)
    }

    private func normalizedOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private func previewJPEG(_ image: CIImage) throws -> Data {
        let scale = min(1, 1600 / max(image.extent.width, image.extent.height))
        let small = normalizedOrigin(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        guard let cgImage = context.createCGImage(small, from: small.extent.integral,
                                                 format: .RGBA8, colorSpace: colorSpace) else {
            throw CameraError.captureFailed
        }
        return try encodeJPEG(cgImage, quality: 0.9)
    }

    private func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraError.captureFailed
        }
        // 明确白名单：方向 + JPEG 质量。绝不拷贝相机 MakerApple、焦点、辅助深度或 Recipe。
        // 虚拟 f 值也不会伪装成真实镜头光圈写入 EXIF。
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraError.captureFailed }
        return data as Data
    }
}
