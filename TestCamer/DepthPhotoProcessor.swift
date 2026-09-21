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
        guard !original.extent.isEmpty, !original.extent.isInfinite,
              let originalCGImage = context.createCGImage(original, from: original.extent,
                                                          format: .RGBA8, colorSpace: colorSpace) else {
            throw CameraError.captureFailed
        }

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
                      filter.inputKeys.contains("inputAperture"), filter.inputKeys.contains("inputFocusRect") {
                // 工厂会准备原生景深需要的辅助信息；不要再 setDefaults() 把这些信息清空。
                filter.setValue(NSNumber(value: photo.options.aperture), forKey: "inputAperture")
                var focusSource = "system"
                if let point = photo.options.focusPoint {
                    // AVCapture 的对焦坐标以传感器左上为原点；Core Image 是左下。
                    // 先转换到原始照片，再与 RGB/深度应用同一 EXIF 旋转/镜像。
                    let sensorPoint = CGPoint(x: rawImage.extent.minX + point.x * rawImage.extent.width,
                                              y: rawImage.extent.minY + (1 - point.y) * rawImage.extent.height)
                    let uprightPoint = sensorPoint.applying(rawImage.orientationTransform(for: orientation))
                    let orientedExtent = rawImage.oriented(orientation).extent
                    let normalizedPoint = CGPoint(x: (uprightPoint.x - orientedExtent.minX) / orientedExtent.width,
                                                  y: (uprightPoint.y - orientedExtent.minY) / orientedExtent.height)
                    filter.setValue(CIVector(cgRect: focusRectangle(at: normalizedPoint)), forKey: "inputFocusRect")
                    focusSource = "tap"
                }
                renderedCGImage = renderDepthFilter(filter, extent: original.extent)
                var change = renderedCGImage.map { pixelDifference($0, originalCGImage) } ?? 0
                // 非人脸、偏中心主体时，系统可能把背景选为清晰面，返回完全未变的图像。
                // 只有自动选择无效才用本张真实视差寻找近景；不覆盖用户主动点选的背景。
                if renderedCGImage != nil, change < 0.5, photo.options.focusPoint == nil,
                   let rectangle = foregroundFocusRectangle(in: disparity) {
                    filter.setValue(CIVector(cgRect: rectangle), forKey: "inputFocusRect")
                    focusSource = "depth-foreground"
                    renderedCGImage = renderDepthFilter(filter, extent: original.extent)
                    change = renderedCGImage.map { pixelDifference($0, originalCGImage) } ?? 0
                }
                if renderedCGImage == nil {
                    outcome = .renderFailed
                } else if change < 0.5 {
                    outcome = .noVisibleEffect
                    renderedCGImage = nil
                } else {
                    outcome = .applied
                }
                print(String(format: "[Depth] native focus=%@, virtual f/%.1f, pixelChange=%.3f/255 (linear RGB)",
                             focusSource, photo.options.aperture, change))
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
            renderedCGImage = originalCGImage
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

    private func renderDepthFilter(_ filter: CIFilter, extent: CGRect) -> CGImage? {
        guard let image = filter.outputImage else { return nil }
        return context.createCGImage(image.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: colorSpace)
    }

    private func focusRectangle(at point: CGPoint) -> CGRect {
        let side: CGFloat = 0.06
        return CGRect(x: min(max(point.x - side / 2, 0), 1 - side),
                      y: min(max(point.y - side / 2, 0), 1 - side), width: side, height: side)
    }

    /// 在真实视差上寻找连续的近景小区域。3×3 的最小值可排除孤立的异常高值，
    /// 相同深度优先靠近画面中心；采样只用于选焦点，不改滤镜收到的原始视差。
    private func foregroundFocusRectangle(in disparity: CIImage) -> CGRect? {
        let size = 48
        let small = normalizedOrigin(disparity).transformed(by: CGAffineTransform(
            scaleX: CGFloat(size) / disparity.extent.width, y: CGFloat(size) / disparity.extent.height))
        var samples = [Float](repeating: 0, count: size * size)
        context.render(small, toBitmap: &samples, rowBytes: size * MemoryLayout<Float>.stride,
                       bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .Rf, colorSpace: nil)
        var bestDepth: Float = 0
        var bestDistance = CGFloat.infinity
        var bestPoint: CGPoint?
        for y in 2..<(size - 2) {
            for x in 2..<(size - 2) {
                var nearestPlane = Float.infinity
                for dy in -1...1 {
                    for dx in -1...1 {
                        let value = samples[(y + dy) * size + x + dx]
                        nearestPlane = value.isFinite && value > 0 ? min(nearestPlane, value) : 0
                    }
                }
                let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(size),
                                    y: 1 - (CGFloat(y) + 0.5) / CGFloat(size))
                let distance = pow(point.x - 0.5, 2) + pow(point.y - 0.5, 2)
                if nearestPlane > bestDepth || (nearestPlane == bestDepth && distance < bestDistance) {
                    bestDepth = nearestPlane
                    bestDistance = distance
                    bestPoint = point
                }
            }
        }
        guard bestDepth > 0, let point = bestPoint else { return nil }
        return focusRectangle(at: point)
    }

    /// 在原分辨率先求差再规约。先缩图会把细纹理的虚化差异抹掉，误丢弃有效成片。
    private func pixelDifference(_ result: CGImage, _ original: CGImage) -> Double {
        let before = CIImage(cgImage: original)
        let difference = CIImage(cgImage: result).applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: before
        ])
        let average = difference.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: before.extent)
        ])
        var pixel = [Float](repeating: 0, count: 4)
        // 不对差值做 sRGB 编码；读取同一工作空间下的线性 RGB 平均差。
        context.render(average, toBitmap: &pixel, rowBytes: 4 * MemoryLayout<Float>.stride,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(pixel[0] + pixel[1] + pixel[2]) / 3 * 255
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
