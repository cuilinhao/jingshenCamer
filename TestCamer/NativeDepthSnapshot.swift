// NativeDepthSnapshot.swift
// 直接从同一次 AVCapturePhoto.depthData 拷贝成 Sendable 值，避免依赖 HEIC 辅助附件重读。
// 不持有跨队列可变 CVPixelBuffer；也不建立实时深度输出。
import Foundation
@preconcurrency import AVFoundation
import CoreVideo

struct NativeDepthSnapshot: Sendable {
    /// 尚未应用 EXIF，和原始照片坐标一致。
    let raster: DepthRaster
    let quality: String
    let accuracy: String
    let filtered: Bool

}

extension NativeDepthSnapshot {
    init(depthData: AVDepthData) throws {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = converted.depthDataMap
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let strideBytes = CVPixelBufferGetBytesPerRow(map)
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DisparityFloat32,
              width > 0, height > 0, width <= 4096, height <= 4096,
              strideBytes >= width * MemoryLayout<Float>.stride,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else {
            throw DepthAnalysisError.invalidBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { throw DepthAnalysisError.invalidBuffer }
        var pixels = [Float](repeating: 0, count: width*height)
        pixels.withUnsafeMutableBufferPointer { destination in
            guard let output = destination.baseAddress else { return }
            for y in 0..<height {
                let row = base.advanced(by: y*strideBytes).assumingMemoryBound(to: Float.self)
                output.advanced(by: y*width).update(from: row, count: width)
            }
        }
        raster = try DepthRaster(width: width, height: height, values: pixels)
        quality = converted.depthDataQuality == .high ? "high" : "low"
        accuracy = converted.depthDataAccuracy == .absolute ? "absolute" : "relative"
        filtered = converted.isDepthDataFiltered
    }

}

/// 同一次快门的原生人物遮罩。它只保护人物清晰区域，不能代替真实深度。
/// 行数据已经去掉像素缓冲区的 padding，仍保持未应用 EXIF 的左上原点坐标。
struct NativePortraitMatteSnapshot: Sendable {
    let width: Int
    let height: Int
    let pixels: Data

    init(portraitEffectsMatte: AVPortraitEffectsMatte) throws {
        let buffer = portraitEffectsMatte.mattingImage
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              width > 0, height > 0, width <= 8192, height <= 8192,
              stride >= width,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw DepthAnalysisError.invalidBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw DepthAnalysisError.invalidBuffer
        }
        var pixels = Data(count: width * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                target.advanced(by: row * width)
                    .copyMemory(from: base.advanced(by: row * stride), byteCount: width)
            }
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
