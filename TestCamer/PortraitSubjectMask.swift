// 同帧人物选择：返回所选实例的置信遮罩，不生成或替代深度。
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import CoreVideo
@preconcurrency import Vision

struct PortraitSubjectSelection {
    /// 白色表示可靠人物区域；与正向原图具有相同 extent，具体用途由渲染器决定。
    let mask: CIImage
    let focusPoint: NormalizedImagePoint
    let source: String
    /// Optional face center verified inside the selected final mask, in upright coordinates.
    let facePoint: NormalizedImagePoint?

    init(mask: CIImage, focusPoint: NormalizedImagePoint, source: String,
         facePoint: NormalizedImagePoint? = nil) {
        self.mask = mask; self.focusPoint = focusPoint; self.source = source; self.facePoint = facePoint
    }
}

struct PortraitSubjectMask {
    let context: CIContext

    /// 点按落在人物内部时只选择该人物；没有点按时自动选择画面中面积最大的一个人。
    /// 所有选择仅存在于这次渲染中。调用方须另行确认原生或估计深度有效。
    func select(in uprightImage: CIImage, nativeMatte: NativePortraitMatteSnapshot?,
                exif: UInt32, tap: NormalizedImagePoint?, captureID: Int64? = nil,
                includeFaceAnchor: Bool = false) -> PortraitSubjectSelection? {
        let started = ProcessInfo.processInfo.systemUptime
        func log(_ event: String) {
            TestLog.shared.record(event, category: "portrait", captureID: captureID)
        }
        log("selection start nativeMatte=\(nativeMatte != nil) tapGiven=\(tap != nil) exif=\(exif)")
        defer { log(String(format: "selection finished seconds=%.3f", ProcessInfo.processInfo.systemUptime - started)) }
        guard !uprightImage.extent.isEmpty, !uprightImage.extent.isInfinite,
              tap == nil || tap!.isValid else {
            log("selection none reason=invalid_image_extent_or_tap")
            return nil
        }
        let scale = min(1, 1600 / max(uprightImage.extent.width, uprightImage.extent.height))
        let analysisImage = uprightImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let handler = VNImageRequestHandler(ciImage: analysisImage, orientation: .up, options: [:])
        let request = VNGeneratePersonInstanceMaskRequest()
        do {
            let instanceStarted = ProcessInfo.processInfo.systemUptime
            log("instance request start analysisSize=\(Int(analysisImage.extent.width))x\(Int(analysisImage.extent.height))")
            try handler.perform([request])
            log(String(format: "instance request complete observations=%d instances=%d seconds=%.3f",
                request.results?.count ?? 0, request.results?.first?.allInstances.count ?? 0,
                ProcessInfo.processInfo.systemUptime - instanceStarted))
            guard let observation = request.results?.first else {
                log("selection none reason=no_instance_observation")
                return nil
            }
            guard let labels = InstanceLabels(buffer: observation.instanceMask) else {
                log("selection none reason=invalid_instance_label_buffer format=\(CVPixelBufferGetPixelFormatType(observation.instanceMask))")
                return nil
            }
            if let instance = labels.selectedInstance(at: tap, candidates: observation.allInstances) {
                log("instance selected tapInside=\(tap == nil ? "not_applicable" : "true")")
                let maskStarted = ProcessInfo.processInfo.systemUptime
                log("instance scaled mask start")
                let buffer = try observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: instance), from: handler)
                log(String(format: "instance scaled mask complete seconds=%.3f", ProcessInfo.processInfo.systemUptime - maskStarted))
                let selectedMask = fitted(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]),
                                          to: uprightImage.extent)
                // 标签图用于实例选择；精细 alpha 再确认点按没有落在轮廓外的背景。
                if let tap, value(in: selectedMask, at: tap) < 0.5 {
                    log("selection none reason=tap_outside_fine_instance_mask tapInside=false")
                    return nil
                }
                let face = tap == nil || includeFaceAnchor
                    ? facePoint(in: analysisImage, selectedMask: selectedMask, captureID: captureID) : nil
                let point = tap ?? face
                    ?? labels.interiorPoint(for: instance)
                guard let point else {
                    log("selection none reason=no_interior_focus_candidate")
                    return nil
                }
                // 原生 matte 包含全部人物，仅单人场景能直接使用它的精细发丝边缘。
                // 多人始终使用选中实例的遮罩，不能把其他人也拼回清晰原图。
                if observation.allInstances.count == 1 {
                    if let native = nativeMask(nativeMatte, exif: exif, extent: uprightImage.extent, captureID: captureID) {
                        if value(in: native, at: point) >= 0.5 {
                            log("selection accepted source=native_single_person " + coverageSummary(native))
                            return PortraitSubjectSelection(mask: native, focusPoint: point,
                                source: "同帧原生人物保护（单人）",
                                facePoint: includeFaceAnchor ? face.flatMap { value(in: native, at: $0) >= 0.9 ? $0 : nil } : nil)
                        }
                        log("native matte rejected reason=focus_candidate_outside_matte; trying_vision_segmentation")
                    }
                } else {
                    log("native matte bypass reason=multiple_person_instances; using_selected_instance")
                }
                // 实例模型擅长分人，但高分辨率 alpha 会把邻近物体带入低置信灰区。
                // 用 accurate 人物分割保留轮廓，实例只限制选择的是哪一个人。
                guard let personMask = accuratePersonMask(handler: handler, extent: uprightImage.extent,
                                                         captureID: captureID) else {
                    log("selection none reason=accurate_person_mask_unavailable")
                    return nil
                }
                let protection: CIImage
                if observation.allInstances.count == 1 {
                    protection = personMask
                } else {
                    let instanceRegion = selectedMask.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 8, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 8, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 8, w: 0),
                        "inputBiasVector": CIVector(x: -3, y: -3, z: -3, w: 0)
                    ]).applyingFilter("CIColorClamp")
                        .applyingFilter("CIMorphologyMaximum", parameters: [
                            "inputRadius": max(2, max(uprightImage.extent.width, uprightImage.extent.height) * 0.004)
                        ]).cropped(to: uprightImage.extent)
                    protection = personMask.applyingFilter("CIMinimumCompositing", parameters: [
                        kCIInputBackgroundImageKey: instanceRegion
                    ]).cropped(to: uprightImage.extent)
                }
                guard value(in: protection, at: point) >= 0.5 else {
                    log("selection none reason=focus_candidate_outside_final_protection")
                    return nil
                }
                log("selection accepted source=vision selectedBy=\(tap == nil ? "automatic" : "tap") " + coverageSummary(protection))
                return PortraitSubjectSelection(mask: protection, focusPoint: point,
                    source: tap == nil ? "自动人物实例保护" : "点选人物实例保护",
                    facePoint: includeFaceAnchor ? face.flatMap { value(in: protection, at: $0) >= 0.9 ? $0 : nil } : nil)
            }
            // 实例模型确认无人或点中背景时不允许 aggregate 遮罩改变用户选择。
            log("selection none reason=\(tap == nil ? "no_person_instance" : "tap_outside_person_instances") " +
                "tapInside=\(tap == nil ? "not_applicable" : "false")")
            return nil
        } catch {
            log("instance request_or_mask failed \(TestLog.errorDescription(error)); trying_single_person_fallback")
            // 只有实例请求不可用才退回单人路径；多个人不能共用全人物遮罩。
            return singlePersonFallback(image: analysisImage, fullExtent: uprightImage.extent,
                                        nativeMatte: nativeMatte, exif: exif, tap: tap, captureID: captureID,
                                        includeFaceAnchor: includeFaceAnchor)
        }
    }

    private func singlePersonFallback(image: CIImage, fullExtent: CGRect,
                                      nativeMatte: NativePortraitMatteSnapshot?, exif: UInt32,
                                      tap: NormalizedImagePoint?, captureID: Int64?,
                                      includeFaceAnchor: Bool) -> PortraitSubjectSelection? {
        func log(_ event: String) { TestLog.shared.record(event, category: "portrait", captureID: captureID) }
        let started = ProcessInfo.processInfo.systemUptime
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        do {
            log("single-person fallback detection start")
            try handler.perform([people])
            let count = (people.results ?? []).filter({ $0.confidence >= 0.5 }).count
            log(String(format: "single-person fallback detection complete acceptedPeople=%d seconds=%.3f",
                       count, ProcessInfo.processInfo.systemUptime - started))
            guard count == 1 else {
                log("selection none reason=fallback_requires_exactly_one_person")
                return nil
            }
            let mask: CIImage
            let source: String
            if let native = nativeMask(nativeMatte, exif: exif, extent: fullExtent, captureID: captureID) {
                mask = native
                source = "同帧原生人物保护（单人回退）"
            } else {
                guard let generated = accuratePersonMask(handler: handler, extent: fullExtent, captureID: captureID) else {
                    log("selection none reason=fallback_person_mask_unavailable")
                    return nil
                }
                mask = generated
                source = "人物分割保护（单人回退）"
            }
            if let tap, value(in: mask, at: tap) < 0.5 {
                log("selection none reason=tap_outside_fallback_mask tapInside=false")
                return nil
            }
            let face = tap == nil || includeFaceAnchor
                ? facePoint(in: image, selectedMask: mask, captureID: captureID) : nil
            guard let point = tap ?? face
                    ?? interiorPoint(in: mask) else {
                log("selection none reason=fallback_has_no_interior_focus_candidate")
                return nil
            }
            log("selection accepted source=\(source) tapInside=\(tap == nil ? "not_applicable" : "true") " + coverageSummary(mask))
            return PortraitSubjectSelection(mask: mask, focusPoint: point, source: source,
                facePoint: includeFaceAnchor ? face.flatMap { value(in: mask, at: $0) >= 0.9 ? $0 : nil } : nil)
        } catch {
            log("selection none reason=single_person_fallback_failed \(TestLog.errorDescription(error))")
            return nil
        }
    }

    private func accuratePersonMask(handler: VNImageRequestHandler, extent: CGRect, captureID: Int64?) -> CIImage? {
        func log(_ event: String) { TestLog.shared.record(event, category: "portrait", captureID: captureID) }
        let started = ProcessInfo.processInfo.systemUptime
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            log("accurate segmentation start")
            try handler.perform([request])
            guard let result = request.results?.first else {
                log("accurate segmentation unavailable reason=no_observation")
                return nil
            }
            log(String(format: "accurate segmentation complete size=%dx%d seconds=%.3f",
                CVPixelBufferGetWidth(result.pixelBuffer), CVPixelBufferGetHeight(result.pixelBuffer),
                ProcessInfo.processInfo.systemUptime - started))
            return fitted(CIImage(cvPixelBuffer: result.pixelBuffer, options: [.colorSpace: NSNull()]), to: extent)
        } catch {
            log("accurate segmentation failed \(TestLog.errorDescription(error))")
            return nil
        }
    }

    private func facePoint(in image: CIImage, selectedMask: CIImage, captureID: Int64?) -> NormalizedImagePoint? {
        let request = VNDetectFaceRectanglesRequest()
        let started = ProcessInfo.processInfo.systemUptime
        TestLog.shared.record("face candidate detection start", category: "portrait", captureID: captureID)
        do {
            try VNImageRequestHandler(ciImage: image, orientation: .up, options: [:]).perform([request])
        } catch {
            TestLog.shared.record("face candidate detection failed \(TestLog.errorDescription(error))",
                                  category: "portrait", captureID: captureID)
        }
        let point = (request.results ?? []).filter { $0.confidence >= 0.4 }
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
            .map { NormalizedImagePoint(x: Double($0.boundingBox.midX), y: Double(1 - $0.boundingBox.midY)) }
            .first { value(in: selectedMask, at: $0) >= 0.8 }
        TestLog.shared.record(String(format: "face candidate detection complete count=%d selectedInsideMask=%@ seconds=%.3f",
            request.results?.count ?? 0, point == nil ? "false" : "true", ProcessInfo.processInfo.systemUptime - started),
            category: "portrait", captureID: captureID)
        return point
    }

    private func nativeMask(_ snapshot: NativePortraitMatteSnapshot?, exif: UInt32, extent: CGRect,
                            captureID: Int64?) -> CIImage? {
        func log(_ event: String) { TestLog.shared.record(event, category: "portrait", captureID: captureID) }
        guard let snapshot else {
            log("native matte unavailable reason=not_delivered_or_not_copied")
            return nil
        }
        guard let provider = CGDataProvider(data: snapshot.pixels as CFData),
              let cg = CGImage(width: snapshot.width, height: snapshot.height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: snapshot.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            log("native matte unavailable reason=image_creation_failed")
            return nil
        }
        let oriented = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            .oriented(CGImagePropertyOrientation(rawValue: exif) ?? .up)
        let ratio = oriented.extent.width / oriented.extent.height
        guard abs(ratio / (extent.width / extent.height) - 1) < 0.02 else {
            log("native matte unavailable reason=aspect_ratio_mismatch uprightSize=\(Int(oriented.extent.width))x\(Int(oriented.extent.height))")
            return nil
        }
        log("native matte ready inputSize=\(snapshot.width)x\(snapshot.height) exif=\(exif)")
        return fitted(oriented, to: extent)
    }

    /// 诊断只保存小图采样的覆盖比例，不保存遮罩或选区坐标。
    private func coverageSummary(_ mask: CIImage) -> String {
        let scale = min(1, 128 / max(mask.extent.width, mask.extent.height))
        let small = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(small.extent.width.rounded()))
        let height = max(1, Int(small.extent.height.rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(small, toBitmap: base, rowBytes: width,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .R8, colorSpace: nil)
        }
        let covered = pixels.filter { $0 >= 128 }.count
        let average = Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) / 255
        return String(format: "protectionCoverage=%.2f%% meanProtection=%.2f%% sampleSize=%dx%d",
                      Double(covered) / Double(pixels.count) * 100, average * 100, width, height)
    }

    private func fitted(_ image: CIImage, to extent: CGRect) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width,
                                               y: extent.height / image.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private func value(in mask: CIImage, at point: NormalizedImagePoint) -> Float {
        guard point.isValid else { return 0 }
        let x = mask.extent.minX + min(mask.extent.width - 1, point.x * mask.extent.width)
        let y = mask.extent.minY + min(mask.extent.height - 1, (1 - point.y) * mask.extent.height)
        var pixel: Float = 0
        context.render(mask, toBitmap: &pixel, rowBytes: MemoryLayout<Float>.stride,
                       bounds: CGRect(x: floor(x), y: floor(y), width: 1, height: 1),
                       format: .Rf, colorSpace: nil)
        return pixel
    }

    private func interiorPoint(in mask: CIImage) -> NormalizedImagePoint? {
        // 用稀疏网格寻找遮罩内部最靠近中心的可靠点，不把空洞中的质心当作人物。
        var candidates: [NormalizedImagePoint] = []
        for y in stride(from: 0.05, through: 0.95, by: 0.05) {
            for x in stride(from: 0.05, through: 0.95, by: 0.05) {
                let point = NormalizedImagePoint(x: x, y: y)
                if value(in: mask, at: point) >= 0.95 { candidates.append(point) }
            }
        }
        return candidates.min { hypot($0.x - 0.5, $0.y - 0.5) < hypot($1.x - 0.5, $1.y - 0.5) }
    }
}

/// Vision 的实例标签按左上原点排列；0 是背景，其余值对应 observation.allInstances。
private struct InstanceLabels {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, rowBytes >= width else { return nil }
        var values = [UInt8](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                target.advanced(by: row * width).copyMemory(from: base.advanced(by: row * rowBytes), byteCount: width)
            }
        }
        self.width = width
        self.height = height
        pixels = values
    }

    func selectedInstance(at tap: NormalizedImagePoint?, candidates: IndexSet) -> Int? {
        if let tap {
            guard tap.isValid else { return nil }
            let x = min(width - 1, Int(tap.x * Double(width)))
            let y = min(height - 1, Int(tap.y * Double(height)))
            let label = Int(pixels[y * width + x])
            return candidates.contains(label) ? label : nil
        }
        var counts = [Int](repeating: 0, count: 256)
        for label in pixels { counts[Int(label)] += 1 }
        return candidates.filter { $0 > 0 && $0 < counts.count && counts[$0] > 0 }
            .max { counts[$0] < counts[$1] }
    }

    func interiorPoint(for instance: Int) -> NormalizedImagePoint? {
        let indices = pixels.indices.filter { Int(pixels[$0]) == instance }
        guard !indices.isEmpty else { return nil }
        let centerX = Double(indices.reduce(0) { $0 + $1 % width }) / Double(indices.count)
        let centerY = Double(indices.reduce(0) { $0 + $1 / width }) / Double(indices.count)
        let closest = indices.min {
            hypot(Double($0 % width) - centerX, Double($0 / width) - centerY)
                < hypot(Double($1 % width) - centerX, Double($1 / width) - centerY)
        }!
        return NormalizedImagePoint(x: (Double(closest % width) + 0.5) / Double(width),
                                    y: (Double(closest / width) + 0.5) / Double(height))
    }
}
