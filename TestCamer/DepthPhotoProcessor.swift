// DepthPhotoProcessor.swift — 主摄优先苹果原生景深，其他镜头与失败回退使用计算景深
// 只处理一次快门的照片，不参与普通取景；可编辑源由独立照片存储管理。
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import Vision

struct ProcessedPhoto: Sendable {
    /// 系统相册使用完整分辨率 JPEG；本机可编辑文档另存源文件和参数。
    let jpegData: Data
    let previewData: Data
    let originalPreviewData: Data
    let diagnosticMaskData: Data?
    /// 不含坐标、焦平面距离或人脸框，只含能力、质量和输出检查信息。
    var diagnosticText: String
    let outcome: DepthRenderOutcome
    let aperture: Float
    let pixelWidth: Int
    let pixelHeight: Int
    let captureID: Int64?
    let renderer: DepthRenderingMethod
    let usedAppleMetadataCompatibility: Bool
    let diagnosticImageIsDifference: Bool
    var legacyComparison: LegacyDepthComparison? = nil
    /// 景深成功时保留实际初始焦点，供本机拍后编辑准确恢复。
    var editRecipe: PhotoEditRecipe? = nil
    /// 传感器坐标的不可变视差附件；与原始容器一起保存在本机。
    var editDepthData: Data? = nil
    /// 本次确实从苹果路径回退；供 UI 展示结果，不根据所选镜头猜测。
    var appleFallbackReason: String? = nil

    var rendererTitle: String {
        usedAppleMetadataCompatibility ? "苹果景深（兼容）" : renderer.title
    }
}

struct LegacyDepthComparison: Sendable {
    let previewData: Data
    let outcome: DepthRenderOutcome
}

/// CIContext 与可变渲染状态仅由 renderQueue 使用。异步调用不阻塞相机/UI 主线程。
final class DepthPhotoProcessor: @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "com.testcamer.photo-depth", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let depthEstimator: (@Sendable (CIImage) throws -> DepthRaster)?
    private lazy var monocularEstimator = MonocularDepthEstimator(context: context)

    init(depthEstimator: (@Sendable (CIImage) throws -> DepthRaster)? = nil) {
        self.depthEstimator = depthEstimator
    }

    func process(_ photo: CapturedPhoto, renderer requestedRenderer: DepthRenderingMethod? = nil,
                 includeLegacyComparison: Bool = false) async throws -> ProcessedPhoto {
        let queued = ProcessInfo.processInfo.systemUptime
        let prefersApple = requestedRenderer == nil && photo.prefersAppleDepth && photo.options.enabled
        let canTryApple = photo.depthRequested && photo.hasDepthData && photo.nativeDepth != nil
        let renderer = requestedRenderer ?? (prefersApple && canTryApple ? .apple : .computational)
        TestLog.shared.record("process queued bytes=\(photo.data.count) enabled=\(photo.options.enabled) " +
            "depthRequested=\(photo.depthRequested) hasDepth=\(photo.hasDepthData) " +
            "nativeDepth=\(photo.nativeDepth != nil) nativeMatte=\(photo.nativePortraitMatte != nil) " +
            "tapGiven=\(photo.transientDeviceFocus != nil) prefersApple=\(prefersApple)", category: "processor", captureID: photo.captureID)
        return try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                TestLog.shared.record(String(format: "process started queueSeconds=%.3f",
                    ProcessInfo.processInfo.systemUptime - queued), category: "processor", captureID: photo.captureID)
                let result: Result<ProcessedPhoto, Error> = autoreleasepool {
                    Result {
                        var primary = try render(photo, renderer: renderer)
                        var appleFallbackReason: String?
                        if prefersApple, renderer == .apple, !primary.outcome.canCompare {
                            appleFallbackReason = primary.outcome.rawValue
                            primary = try render(photo, renderer: .computational)
                        } else if prefersApple, renderer != .apple {
                            appleFallbackReason = "native depth unavailable"
                        }
                        if let reason = appleFallbackReason {
                            primary.appleFallbackReason = reason
                            let note = "preferredRenderer=apple\nappleFallbackReason=\(reason)\nactualRenderer=\(primary.renderer.rawValue)"
                            primary.diagnosticText += "\n" + note
                            TestLog.shared.record(note, category: "processor", captureID: photo.captureID)
                        }
                        if includeLegacyComparison, primary.renderer == .apple, photo.options.enabled,
                           photo.hasDepthData, photo.nativeDepth != nil {
                            // 串行处理完全相同的输入；仅保留旧版预览，不能影响主结果或保存目标。
                            do {
                                let comparison = try autoreleasepool { try render(photo, renderer: .legacy) }
                                primary.legacyComparison = LegacyDepthComparison(
                                    previewData: comparison.previewData, outcome: comparison.outcome)
                            } catch {
                                TestLog.shared.record("legacy comparison failed: \(TestLog.errorDescription(error))",
                                                      category: "processor", captureID: photo.captureID)
                            }
                        }
                        return primary
                    }
                }
                if case .failure(let error) = result {
                    TestLog.shared.record("process failed \(TestLog.errorDescription(error))",
                                          category: "processor", captureID: photo.captureID)
                }
                continuation.resume(with: result)
            }
        }
    }

    private func render(_ photo: CapturedPhoto, renderer: DepthRenderingMethod) throws -> ProcessedPhoto {
        dispatchPrecondition(condition: .onQueue(renderQueue))
        if renderer == .computational { return try renderComputational(photo) }
        let started = Date()
        defer { context.clearCaches() }
        var stage = "decode"
        var stageStarted = ProcessInfo.processInfo.systemUptime
        func log(_ event: String) {
            TestLog.shared.record(event, category: "processor", captureID: photo.captureID)
        }
        func begin(_ name: String) {
            stage = name
            stageStarted = ProcessInfo.processInfo.systemUptime
            log("stage start=\(name)")
        }
        func finish(_ details: String = "") {
            log(String(format: "stage complete=%@ seconds=%.3f %@", stage,
                       ProcessInfo.processInfo.systemUptime - stageStarted, details))
        }
        var completed = false
        defer {
            if !completed {
                log(String(format: "process aborted stage=%@ stageSeconds=%.3f", stage,
                           ProcessInfo.processInfo.systemUptime - stageStarted))
            }
        }
        begin("decode")
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let rawImage = CIImage(data: photo.data, options: [.applyOrientationProperty: false]) else {
            log("stage failed=decode reason=image_source_or_ciimage_unavailable")
            throw CameraError.captureFailed
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let exif = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: exif) ?? .up
        let original = normalizedOrigin(rawImage.oriented(orientation))
            .settingProperties([kCGImagePropertyOrientation as String: 1])
        guard !original.extent.isEmpty, !original.extent.isInfinite else {
            log("stage failed=decode reason=invalid_image_extent")
            throw CameraError.captureFailed
        }
        finish("raw=\(Int(rawImage.extent.width))x\(Int(rawImage.extent.height)) " +
               "upright=\(Int(original.extent.width))x\(Int(original.extent.height)) exif=\(orientation.rawValue)")
        var notes = ["TestCamer PostCaptureDepth v3", "requestedRenderer=\(renderer.rawValue)", photo.captureSummary,
                     "photoUpright=\(Int(original.extent.width))x\(Int(original.extent.height))",
                     "exifApplied=\(orientation.rawValue)",
                     String(format: "virtualAperture=f/%.1f", photo.options.aperture)]
        var outcome: DepthRenderOutcome = .renderFailed
        var outputCG: CGImage?
        var diagnosticMaskData: Data?
        var usedAppleMetadataCompatibility = false
        var selectedEditRecipe: PhotoEditRecipe?

        if !photo.options.enabled {
            outcome = .disabled
            log("depth bypass reason=option_disabled")
        } else if !photo.depthRequested {
            outcome = .unsupported
            log("depth bypass reason=not_requested_or_unsupported")
        } else if !photo.hasDepthData {
            outcome = .missingDepth
            log("depth bypass reason=camera_did_not_deliver_depth")
        } else if let nativeDepth = photo.nativeDepth {
            do {
                begin("depth_orientation_and_statistics")
                // 同一套 EXIF 变换只应用一次，原图和视差宽高/旋转/镜像必须一致。
                let depth = nativeDepth.raster.oriented(exif: orientation.rawValue)
                notes += ["depthUpright=\(depth.width)x\(depth.height)",
                          "depthQuality=\(nativeDepth.quality)", "depthAccuracy=\(nativeDepth.accuracy)",
                          "depthFiltered=\(nativeDepth.filtered)", "depthSource=AVCapturePhoto.depthData (direct)"]
                finish("size=\(depth.width)x\(depth.height) quality=\(nativeDepth.quality) " +
                       "accuracy=\(nativeDepth.accuracy) filtered=\(nativeDepth.filtered) " + depthStatistics(depth))
                begin("subject_selection")
                // 两套算法采用相同的选焦规则。自动模式选最大可用人脸，否则中心；
                // 苹果路径不再将整个选中人物用原图强行覆盖回去。
                let selection = choosePlane(original: original, depth: depth,
                    transientDeviceFocus: photo.transientDeviceFocus, exif: orientation.rawValue,
                    captureID: photo.captureID)
                let focus = selection.point ?? NormalizedImagePoint(x: 0.5, y: 0.5)
                notes.append("selection=\(selection.source)") // 不记录点位或人脸框。
                finish("source=\(selection.source)")
                let result: DepthBlurOutput
                if renderer == .apple {
                    // A usable map may still have a hole exactly under the
                    // selected point. Avoid saving an initial recipe that the
                    // post-capture editor cannot reliably reproduce.
                    guard depth.value(at: focus) != nil else { throw DepthAnalysisError.focusUnavailable }
                    begin("apple_depth_render")
                    let inverseEXIF: UInt32 = exif == 6 ? 8 : (exif == 8 ? 6 : exif)
                    let sensorFocus = focus.oriented(exif: inverseEXIF)
                    selectedEditRecipe = PhotoEditRecipe(aperture: photo.options.aperture, sensorFocus: sensorFocus)
                    let apple = try AppleDepthRenderer(context: context).render(photoData: photo.data,
                        aperture: photo.options.aperture, sensorFocus: sensorFocus)
                    usedAppleMetadataCompatibility = apple.usedMetadataCompatibility
                    guard apple.image.extent == original.extent else { throw DepthAnalysisError.alignmentMismatch }
                    // 官方滤镜没有公开其内部虚化量图。全图仅用于输出变化统计，
                    // 下方诊断另生成差异图，不能把白色统计选区冒充其实际遮罩。
                    let measurementArea = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
                        .cropped(to: original.extent)
                    result = DepthBlurOutput(image: apple.image, amountMask: measurementArea,
                        notes: apple.notes + "\nmeasurementScope=whole image\nwholePersonCompositing=false")
                } else {
                    begin("legacy_depth_render")
                    let subject = PortraitSubjectMask(context: context).select(in: original,
                        nativeMatte: photo.nativePortraitMatte, exif: orientation.rawValue, tap: focus,
                        captureID: photo.captureID)
                    let plan = try DepthMath.makePlan(depth: depth, focus: focus,
                        isPerson: subject != nil || selection.isPerson, aperture: photo.options.aperture)
                    result = try DepthBlurRenderer(context: context, colorSpace: colorSpace)
                        .render(original: original, plan: plan, protectedSubject: subject?.mask)
                }
                notes.append(result.notes)
                finish(result.notes)
                begin("materialize_output")
                guard let cg = context.createCGImage(result.image, from: original.extent,
                                                      format: .RGBA8, colorSpace: colorSpace) else {
                    throw DepthRendererError.imageCreation
                }
                outputCG = cg
                finish("size=\(cg.width)x\(cg.height)")
                begin("measure_output")
                // 检查最终输出像素，不再把“滤镜返回了对象”当成“明显虚化”。
                let measurement: EffectMeasurement = try measure(original: original,
                    result: CIImage(cgImage: cg), mask: result.amountMask)
                notes += [String(format: "eligiblePixels=%d\nmeanChange=%.3f/255\nchangedPixels=%.1f%%",
                                 measurement.eligiblePixelCount, measurement.meanAbsoluteChange*255,
                                 measurement.changedFraction*100),
                          "measurement=output difference only; not a visual quality guarantee"]
                outcome = measurement.hasVisibleChange ? .applied : .weakEffect
                finish(String(format: "eligiblePixels=%d meanChange=%.4f/255 changedPixels=%.2f%% outcome=%@",
                    measurement.eligiblePixelCount, measurement.meanAbsoluteChange * 255,
                    measurement.changedFraction * 100, outcome.rawValue))
                begin("diagnostic_preview")
                if renderer == .apple {
                    let difference = CIImage(cgImage: cg).applyingFilter("CIDifferenceBlendMode",
                        parameters: [kCIInputBackgroundImageKey: original])
                        .applyingFilter("CIMaximumComponent")
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: 4, y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: 4, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: 4, w: 0)
                        ]).cropped(to: original.extent)
                    diagnosticMaskData = try? previewJPEG(difference, maximum: 1200)
                    notes.append("diagnosticImage=output difference amplified 4x; not Apple's internal blur mask")
                } else {
                    diagnosticMaskData = try? previewJPEG(result.amountMask, maximum: 1200)
                    notes.append("diagnosticImage=legacy blur amount")
                }
                finish("available=\(diagnosticMaskData != nil) bytes=\(diagnosticMaskData?.count ?? 0)")
            } catch let error as DepthAnalysisError {
                log("stage failed=\(stage) \(TestLog.errorDescription(error))")
                notes.append("analysisIssue=\(error.localizedDescription)")
                switch error {
                case .insufficientSeparation: outcome = .insufficientSeparation
                case .focusUnavailable: outcome = .focusUnavailable
                case .alignmentMismatch: outcome = .alignmentMismatch
                default: outcome = .invalidDepth
                }
                outputCG = nil
            } catch {
                log("stage failed=\(stage) \(TestLog.errorDescription(error))")
                notes.append("renderIssue=\(error.localizedDescription)")
                outcome = .renderFailed
                outputCG = nil
            }
        } else {
            // 已交付深度但无法复制时应报无效深度，而不是误称设备不支持。
            outcome = .invalidDepth
            log("depth bypass reason=delivered_depth_snapshot_missing")
        }

        if outputCG == nil {
            begin("ordinary_photo_fallback")
            notes.append("fallback=ordinary photo; no synthetic/AI/full-frame blur")
            outputCG = context.createCGImage(original, from: original.extent, format: .RGBA8, colorSpace: colorSpace)
            finish("reason=\(outcome.rawValue) imageAvailable=\(outputCG != nil)")
        }
        guard let image = outputCG else {
            log("output failed reason=no_rendered_or_fallback_image")
            throw CameraError.captureFailed
        }
        begin("encode_jpeg")
        let jpeg = try encodeJPEG(image, quality: 0.95)
        finish("bytes=\(jpeg.count)")
        begin("output_preview")
        let preview = try previewJPEG(CIImage(cgImage: image))
        finish("bytes=\(preview.count)")
        begin("original_preview")
        let before = outcome.canCompare ? try previewJPEG(original) : preview
        finish("canCompare=\(outcome.canCompare) bytes=\(before.count)")
        notes += ["outcome=\(outcome.rawValue)", String(format: "processingSeconds=%.2f", Date().timeIntervalSince(started)),
                  "jpegSize=\(jpeg.count) bytes", "savedFocusMetadata=false", "savedDepthMetadata=false"]
        let diagnosticText = notes.joined(separator: "\n")
        print("[Depth v3]\n\(diagnosticText)")
        log("process complete outcome=\(outcome.rawValue)\n\(diagnosticText)")
        completed = true
        return ProcessedPhoto(jpegData: jpeg, previewData: preview, originalPreviewData: before,
                              diagnosticMaskData: diagnosticMaskData, diagnosticText: diagnosticText,
                              outcome: outcome, aperture: photo.options.aperture,
                              pixelWidth: image.width, pixelHeight: image.height, captureID: photo.captureID,
                              renderer: renderer, usedAppleMetadataCompatibility: usedAppleMetadataCompatibility,
                              diagnosticImageIsDifference: renderer == .apple,
                              editRecipe: renderer == .apple && outcome.canCompare ? selectedEditRecipe : nil)
    }

    /// Native and estimated maps share a renderer and a durable edit format.
    /// No synthetic map is inserted into AVDepthData or labelled metric depth.
    private func renderComputational(_ photo: CapturedPhoto) throws -> ProcessedPhoto {
        defer { context.clearCaches() }
        let started = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let raw = CIImage(data: photo.data, options: [.applyOrientationProperty: false]) else {
            throw CameraError.captureFailed
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let exif = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: exif) ?? .up
        let original = normalizedOrigin(raw.oriented(orientation))
            .settingProperties([kCGImagePropertyOrientation as String: 1])
        guard !original.extent.isEmpty, !original.extent.isInfinite else { throw CameraError.captureFailed }
        var output = original
        var outcome: DepthRenderOutcome = .disabled
        var attachment: Data?
        var recipe: PhotoEditRecipe?
        var diagnostic: Data?
        var notes = ["TestCamer ComputationalDepth v4", photo.captureSummary,
                     "renderer=computational", "exifApplied=\(orientation.rawValue)",
                     "depthUnits=relative disparity; not meters"]
        if photo.options.enabled {
            do {
                let depth: DepthRaster
                let depthSource: PhotoDepthSource
                var nativeSelection: (point: NormalizedImagePoint?, isPerson: Bool, source: String)?
                // A delivered map may contain invalid samples or have the wrong
                // field of view. Those maps cannot suppress the estimator fallback.
                let native = photo.nativeDepth.flatMap { snapshot -> DepthRaster? in
                    let upright = snapshot.raster.oriented(exif: orientation.rawValue)
                    guard abs((CGFloat(upright.width)/CGFloat(upright.height)) /
                              (original.extent.width/original.extent.height) - 1) <= 0.02,
                          let validated = try? PhotoDepthData(raster: upright, source: .native) else { return nil }
                    let selection = choosePlane(original: original, depth: validated.raster,
                        transientDeviceFocus: photo.transientDeviceFocus, exif: orientation.rawValue,
                        captureID: photo.captureID)
                    let point = selection.point ?? NormalizedImagePoint(x: 0.5, y: 0.5)
                    guard validated.raster.value(at: point) != nil else {
                        notes.append("nativeRejected=focus sample unavailable")
                        return nil
                    }
                    do {
                        // Global coverage alone is not enough: the same focus
                        // neighborhood used for rendering must be reliable too.
                        _ = try DepthMath.makePlan(depth: validated.raster, focus: point,
                            isPerson: false, aperture: photo.options.aperture)
                    } catch DepthAnalysisError.insufficientSeparation {
                        // A valid flat scene is not a missing-depth failure.
                    } catch {
                        notes.append("nativeRejected=focus neighborhood or depth unavailable")
                        return nil
                    }
                    nativeSelection = selection
                    return validated.raster
                }
                if let native {
                    depth = native
                    depthSource = .native
                } else {
                    let estimated = try depthEstimator?(original) ?? monocularEstimator.estimate(image: original)
                    depth = try PhotoDepthData(raster: estimated, source: .estimated).raster
                    depthSource = .estimated
                }
                notes += ["depthSource=\(depthSource.rawValue)", depthStatistics(depth)]
                guard abs((CGFloat(depth.width)/CGFloat(depth.height)) /
                          (original.extent.width/original.extent.height) - 1) <= 0.02 else {
                    throw DepthAnalysisError.alignmentMismatch
                }
                let selection = nativeSelection ?? choosePlane(original: original, depth: depth,
                    transientDeviceFocus: photo.transientDeviceFocus, exif: orientation.rawValue,
                    captureID: photo.captureID)
                let focus = selection.point ?? NormalizedImagePoint(x: 0.5, y: 0.5)
                guard depth.value(at: focus) != nil else { throw DepthAnalysisError.focusUnavailable }
                let inverse: UInt32 = exif == 6 ? 8 : (exif == 8 ? 6 : exif)
                let stored = try PhotoDepthData(raster: depth.oriented(exif: inverse), source: depthSource)
                let initial = PhotoEditRecipe(aperture: photo.options.aperture,
                    sensorFocus: photo.transientDeviceFocus ?? focus.oriented(exif: inverse))
                let rendered: DepthBlurOutput
                do {
                    // 首次处理与缓存编辑采用同一人物选择规则；只扩大当前点中实例的清晰带。
                    let subject = PortraitSubjectMask(context: context).select(in: original,
                        nativeMatte: nil, exif: 1, tap: focus, captureID: photo.captureID, includeFaceAnchor: true)
                    rendered = try ComputationalDepthRenderer(context: context, colorSpace: colorSpace)
                        .render(original: original, depth: depth, focus: focus, aperture: initial.aperture,
                                selectedSubject: subject?.mask, selectedSubjectFace: subject?.facePoint)
                } catch DepthAnalysisError.insufficientSeparation {
                    // A flat scene remains editable; inventing separation would
                    // turn a depth effect into an arbitrary full-frame blur.
                    rendered = DepthBlurOutput(image: original,
                        amountMask: CIImage(color: .black).cropped(to: original.extent),
                        notes: "effect=flat scene; original preserved")
                }
                guard let cg = context.createCGImage(rendered.image, from: original.extent,
                    format: .RGBA8, colorSpace: colorSpace) else { throw CameraError.captureFailed }
                output = CIImage(cgImage: cg)
                let measurement = try measure(original: original, result: output, mask: rendered.amountMask)
                outcome = measurement.hasVisibleChange ? .applied : .weakEffect
                notes += [rendered.notes, "selection=\(selection.source)",
                          String(format: "meanChange=%.4f/255", measurement.meanAbsoluteChange * 255)]
                diagnostic = try? previewJPEG(rendered.amountMask, maximum: 1200)
                attachment = try stored.encoded()
                recipe = initial
            } catch {
                output = original
                attachment = nil
                recipe = nil
                diagnostic = nil
                switch error {
                case DepthAnalysisError.focusUnavailable: outcome = .focusUnavailable
                case DepthAnalysisError.alignmentMismatch: outcome = .alignmentMismatch
                default: outcome = .renderFailed
                }
                notes += ["fallback=ordinary photo", "processingIssue=\(error.localizedDescription)"]
                TestLog.shared.record("computational failed \(TestLog.errorDescription(error))",
                    category: "processor", captureID: photo.captureID)
            }
        }
        guard let cg = context.createCGImage(output, from: original.extent, format: .RGBA8,
                                             colorSpace: colorSpace) else { throw CameraError.captureFailed }
        let jpeg = try encodeJPEG(cg, quality: 0.95)
        let preview = try previewJPEG(CIImage(cgImage: cg))
        let before = outcome.canCompare ? try previewJPEG(original) : preview
        notes += ["outcome=\(outcome.rawValue)", "cachedDepth=\(attachment != nil)",
                  String(format: "processingSeconds=%.3f", ProcessInfo.processInfo.systemUptime-started)]
        let text = notes.joined(separator: "\n")
        TestLog.shared.record(text, category: "processor", captureID: photo.captureID)
        return ProcessedPhoto(jpegData: jpeg, previewData: preview, originalPreviewData: before,
            diagnosticMaskData: diagnostic, diagnosticText: text, outcome: outcome,
            aperture: photo.options.aperture, pixelWidth: cg.width, pixelHeight: cg.height,
            captureID: photo.captureID, renderer: .computational, usedAppleMetadataCompatibility: false,
            diagnosticImageIsDifference: false, editRecipe: recipe, editDepthData: attachment)
    }

    /// 点按优先；未点按时，用人脸中心的深度或画面中心深度。Vision 只检测框，不做人像替换。
    /// 点位仅进入本机可编辑参数，不写入系统相册 JPEG 或诊断日志。
    private func choosePlane(original: CIImage, depth: DepthRaster,
                             transientDeviceFocus: NormalizedImagePoint?, exif: UInt32, captureID: Int64?)
        -> (point: NormalizedImagePoint?, isPerson: Bool, source: String) {
        if let devicePoint = transientDeviceFocus {
            let point = devicePoint.oriented(exif: exif)
            // 人物关联由同帧人物 mask 判定；相对视差值的比例不能判断是否同一个人。
            return (point, false, "本次点按")
        }
        let faceCenters = detectFaceCenters(original, captureID: captureID)
        if let face = faceCenters.first(where: { depth.value(at: $0) != nil }) {
            return (face, true, "自动人脸深度平面")
        }
        return (nil, false, "自动中心深度平面")
    }

    private func detectFaceCenters(_ original: CIImage, captureID: Int64?) -> [NormalizedImagePoint] {
        // 限制检测图尺寸，避免为选一个点处理整张 12 MP 图像。
        let scale = min(1, 960/max(original.extent.width, original.extent.height))
        let small = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNDetectFaceRectanglesRequest()
        let started = ProcessInfo.processInfo.systemUptime
        TestLog.shared.record("fallback face detection start", category: "processor", captureID: captureID)
        do {
            try VNImageRequestHandler(ciImage: small, orientation: .up, options: [:]).perform([request])
            TestLog.shared.record(String(format: "fallback face detection complete count=%d accepted=%d seconds=%.3f",
                request.results?.count ?? 0, (request.results ?? []).filter { $0.confidence >= 0.4 }.count,
                ProcessInfo.processInfo.systemUptime - started), category: "processor", captureID: captureID)
            return (request.results ?? []).filter { $0.confidence >= 0.4 }
                .sorted { $0.boundingBox.width*$0.boundingBox.height > $1.boundingBox.width*$1.boundingBox.height }
                .map { NormalizedImagePoint(x: Double($0.boundingBox.midX), y: Double(1-$0.boundingBox.midY)) }
        } catch {
            print("[Depth v3] face detection unavailable; native depth still required")
            TestLog.shared.record("fallback face detection failed \(TestLog.errorDescription(error))",
                                  category: "processor", captureID: captureID)
            return []
        }
    }

    /// 只写分布聚合数值，不记录像素、焦点深度、坐标或人脸框。
    private func depthStatistics(_ depth: DepthRaster) -> String {
        let valid = depth.values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard let minimum = valid.first, let maximum = valid.last else {
            return "validDepth=0% samples=\(depth.values.count)"
        }
        func q(_ fraction: Double) -> Float { valid[Int(Double(valid.count - 1) * fraction)] }
        return String(format: "validDepth=%.2f%% samples=%d min=%.6f q02=%.6f q50=%.6f q98=%.6f max=%.6f robustSpan=%.6f",
            Double(valid.count) / Double(depth.values.count) * 100, depth.values.count,
            minimum, q(0.02), q(0.5), q(0.98), maximum, q(0.98) - q(0.02))
    }

    private func measure(original: CIImage, result: CIImage, mask: CIImage) throws -> EffectMeasurement {
        let long = max(original.extent.width, original.extent.height)
        let w = max(1, Int((original.extent.width/long*640).rounded()))
        let h = max(1, Int((original.extent.height/long*640).rounded()))
        let before = bitmap(original, width: w, height: h, colorSpace: colorSpace)
        let after = bitmap(result, width: w, height: h, colorSpace: colorSpace)
        let maskRGBA = bitmap(mask, width: w, height: h, colorSpace: nil)
        let amount = stride(from: 0, to: maskRGBA.count, by: 4).map { maskRGBA[$0] }
        return try EffectMeasurement(originalRGBA: before, renderedRGBA: after, mask: amount)
    }

    private func bitmap(_ image: CIImage, width: Int, height: Int, colorSpace: CGColorSpace?) -> [UInt8] {
        let resized = normalizedOrigin(image).transformed(by:
            CGAffineTransform(scaleX: CGFloat(width)/image.extent.width, y: CGFloat(height)/image.extent.height))
        var data = [UInt8](repeating: 0, count: width*height*4)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(resized, toBitmap: base, rowBytes: width*4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: colorSpace)
        }
        return data
    }

    private func normalizedOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    private func previewJPEG(_ image: CIImage, maximum: CGFloat = 1600) throws -> Data {
        let scale = min(1, maximum/max(image.extent.width, image.extent.height))
        let small = normalizedOrigin(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        guard let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: colorSpace) else {
            throw CameraError.captureFailed
        }
        return try encodeJPEG(cg, quality: 0.9)
    }
    private func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
            UTType.jpeg.identifier as CFString, 1, nil) else { throw CameraError.captureFailed }
        // 白名单，不复制 MakerApple / 焦点 / 辅助深度。不将虚拟 f 值伪装成物理光圈。
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality,
                                         kCGImagePropertyOrientation: 1]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraError.captureFailed }
        return data as Data
    }
}
