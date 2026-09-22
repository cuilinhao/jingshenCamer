//
//  CameraManager.swift
//  TestCamer
//
//  Created by Linhao-Mac on 2026/9/21.
//  在原 Demo 上修改：普通预览 + 单次拍照深度，不建立实时图像/深度处理链。
//

import Foundation
@preconcurrency import AVFoundation

/// 传给 UI 的不可变快照。UI 不再直接跨线程读取 deviceInput / zoomFactor。
struct CameraState: Sendable {
    let isFront: Bool
    let hasFlash: Bool
    let depthSupported: Bool
    let zoomFactor: CGFloat
    let isRunning: Bool
    let deviceName: String
    let rearLensOptions: [CameraLensOption]
    let selectedRearLensID: String?
    let activeLensName: String
}

enum CameraEvent: Sendable {
    case ready(CameraState)
    case interrupted
    case issue(String)
}

/// @unchecked Sendable 的依据：除只用于连接预览的 session 引用外，所有可变状态
/// 都封闭在 sessionQueue；delegate 也先回到同一队列，外部只得到不可变值。
final class CameraManager: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.testcamer.session", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var deviceInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var isConfigured = false
    private var wantsToRun = false
    private var userDidTapFocus = false
    private var eventHandler: (@Sendable (CameraEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var rearLensOptions: [CameraLensOption] = []
    private var selectedRearDeviceID: String?
    private var rearRawZoom: Double = 1

    private final class PendingCapture {
        let id: Int64
        let options: DepthOptions
        let depthRequested: Bool
        let transientDeviceFocus: NormalizedImagePoint?
        let continuation: CheckedContinuation<CapturedPhoto, Error>
        var result: Result<CapturedPhoto, Error>?

        init(id: Int64, options: DepthOptions, depthRequested: Bool,
             transientDeviceFocus: NormalizedImagePoint?,
             continuation: CheckedContinuation<CapturedPhoto, Error>) {
            self.id = id
            self.options = options
            self.depthRequested = depthRequested
            self.transientDeviceFocus = transientDeviceFocus
            self.continuation = continuation
        }
    }
    private var pendingCapture: PendingCapture?

    override init() {
        super.init()
        installSessionObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func setEventHandler(_ handler: @escaping @Sendable (CameraEvent) -> Void) {
        sessionQueue.async { [self] in eventHandler = handler }
    }

    func requestAccess() async -> Bool {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        TestLog.shared.record("camera permission status=\(authorization.rawValue)", category: "camera")
        switch authorization {
        case .authorized: return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            TestLog.shared.record("camera permission granted=\(granted)", category: "camera")
            return granted
        default: return false
        }
    }

    func prepare() async throws {
        guard await requestAccess() else { throw CameraError.notAuthorized }
        try await onSessionQueue { [self] in
            if !isConfigured { try configureSession(for: position) }
        }
    }

    /// 只有配置完成才启动；调用方 await 后才启用快门，避免“按钮可点、会话还没启动”。
    func start() async throws -> CameraState {
        try await onSessionQueue { [self] in
            guard isConfigured else { throw CameraError.configurationFailed }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                throw CameraError.notAuthorized
            }
            wantsToRun = true
            guard !session.isInterrupted else { throw CameraError.interrupted }
            if !session.isRunning { session.startRunning() }
            guard session.isRunning else { throw CameraError.unavailable }
            TestLog.shared.record("[Camera] running, device=\(deviceInput?.device.localizedName ?? "unknown")")
            return makeState()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            TestLog.shared.record("session stop requested running=\(session.isRunning)", category: "camera")
            wantsToRun = false
            userDidTapFocus = false
            if let pending = pendingCapture {
                finishCapture(id: pending.id, result: .failure(CameraError.interrupted))
            }
            if session.isRunning { session.stopRunning() }
        }
    }

    func currentState() async throws -> CameraState {
        try await onSessionQueue { [self] in makeState() }
    }

    func switchCamera() async throws -> CameraState {
        try await onSessionQueue { [self] in
            guard pendingCapture == nil else { throw CameraError.busy }
            TestLog.shared.record("switch camera requested", category: "camera")
            let previous = position
            let previousRearID = selectedRearDeviceID
            let previousRearZoom = rearRawZoom
            let next: AVCaptureDevice.Position = previous == .back ? .front : .back
            let restart = wantsToRun
            if session.isRunning { session.stopRunning() }
            do {
                try configureSession(for: next)
            } catch {
                // 不能因为切换失败把原来的输入永远移除，留下黑屏。
                TestLog.shared.record("[Camera] switch failed: \(error); restoring previous input")
                selectedRearDeviceID = previousRearID
                rearRawZoom = previousRearZoom
                try? configureSession(for: previous)
                if restart && isConfigured { session.startRunning() }
                throw error
            }
            if restart { session.startRunning() }
            return makeState()
        }
    }

    /// 直接切换到指定物理设备；不因光线、距离或深度能力改用其他镜头。
    func selectRearLens(id: String) async throws -> CameraState {
        try await onSessionQueue { [self] in
            guard pendingCapture == nil else { throw CameraError.busy }
            guard position == .back, let lens = rearLensOptions.first(where: { $0.id == id }) else {
                throw CameraError.unavailable
            }
            let previousID = selectedRearDeviceID
            let previousZoom = rearRawZoom
            let restart = wantsToRun
            if session.isRunning { session.stopRunning() }
            do {
                try configureSession(for: .back, rearLensID: id, rawZoom: 1)
            } catch {
                try? configureSession(for: .back, rearLensID: previousID, rawZoom: previousZoom)
                if restart && isConfigured { session.startRunning() }
                throw error
            }
            if restart { session.startRunning() }
            TestLog.shared.record("physical lens selected=\(lens.title), " +
                "device=\(deviceInput?.device.deviceType.rawValue ?? "unknown"), digitalZoom=\(rearRawZoom), " +
                "depth=\(currentDepthSupported)", category: "camera")
            return makeState()
        }
    }

    /// 捏合只裁切当前物理镜头，不切换其他镜头。
    func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [self] in
            guard pendingCapture == nil, factor.isFinite, let device = deviceInput?.device else { return }
            do {
                do {
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    try applyZoom(Double(factor), to: device)
                }
                eventHandler?(.ready(makeState()))
            } catch {
                TestLog.shared.record("[Camera] zoom rejected: \(error.localizedDescription)")
            }
        }
    }

    /// 保留硬件点按。只记一个“本轮有点按”布尔值，快门时从设备读取点位；不落盘、不输出坐标。
    func focus(at point: CGPoint) {
        sessionQueue.async { [self] in
            guard pendingCapture == nil, let device = deviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                    userDidTapFocus = true
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                TestLog.shared.record("[Camera] hardware autofocus requested; no focus record created")
            } catch {
                TestLog.shared.record("[Camera] focus rejected: \(error.localizedDescription)")
            }
        }
    }

    func capturePhoto(flashMode: AVCaptureDevice.FlashMode, options: DepthOptions,
                      rotationAngle: CGFloat, mirrored: Bool) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard pendingCapture == nil else {
                    TestLog.shared.record("capture rejected: busy", category: "capture")
                    continuation.resume(throwing: CameraError.busy)
                    return
                }
                guard session.isRunning, !session.isInterrupted,
                      let connection = photoOutput.connection(with: .video) else {
                    TestLog.shared.record("capture rejected: session running=\(session.isRunning), interrupted=\(session.isInterrupted)", category: "capture")
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }
                // 在快门时冻结方向/镜像；不能只旋转预览、不设置照片连接。
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrored
                }

                let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                if deviceInput?.device.hasFlash == true && photoOutput.supportedFlashModes.contains(flashMode) {
                    settings.flashMode = flashMode
                } else {
                    settings.flashMode = .off
                }
                settings.photoQualityPrioritization = .quality
                if photoOutput.maxPhotoDimensions.width > 0 {
                    settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                }
                let useDepth = options.enabled && currentDepthSupported
                settings.isDepthDataDeliveryEnabled = useDepth
                settings.isDepthDataFiltered = true
                // 仅内存容器保留原生深度和标定元数据，供苹果景深 factory 使用。
                // 最终保存由处理器重新编码 JPEG，不复制这些附件。
                settings.embedsDepthDataInPhoto = useDepth
                settings.isPortraitEffectsMatteDeliveryEnabled = useDepth
                    && photoOutput.isPortraitEffectsMatteDeliverySupported
                    && photoOutput.isPortraitEffectsMatteDeliveryEnabled
                settings.embedsPortraitEffectsMatteInPhoto = settings.isPortraitEffectsMatteDeliveryEnabled
                settings.enabledSemanticSegmentationMatteTypes = useDepth
                    ? photoOutput.enabledSemanticSegmentationMatteTypes : []
                settings.embedsSemanticSegmentationMattesInPhoto = useDepth

                let transientFocus: NormalizedImagePoint?
                if userDidTapFocus, let point = deviceInput?.device.focusPointOfInterest {
                    transientFocus = NormalizedImagePoint(x: Double(point.x), y: Double(point.y))
                } else { transientFocus = nil }
                userDidTapFocus = false // 此选择只消费一次；不作为可重编辑照片参数保留。
                let id = settings.uniqueID
                pendingCapture = PendingCapture(id: id, options: options, depthRequested: useDepth, transientDeviceFocus: transientFocus,
                                                continuation: continuation)
                TestLog.shared.record("begin enabled=\(options.enabled), depthRequested=\(useDepth), nativeMatteRequested=\(settings.isPortraitEffectsMatteDeliveryEnabled), aperture=\(options.aperture), angle=\(rotationAngle), mirrored=\(mirrored), codec=\(codec.rawValue), flash=\(settings.flashMode.rawValue), tapFocus=\(transientFocus != nil)", category: "capture", captureID: id)
                TestLog.shared.record("semanticMattesRequested=\(settings.enabledSemanticSegmentationMatteTypes.map(\.rawValue).joined(separator: ","))", category: "capture", captureID: id)
                if let device = deviceInput?.device {
                    TestLog.shared.record("deviceType=\(device.deviceType.rawValue), position=\(device.position.rawValue), zoom=\(device.videoZoomFactor), focusMode=\(device.focusMode.rawValue), adjustingFocus=\(device.isAdjustingFocus), adjustingExposure=\(device.isAdjustingExposure), ISO=\(device.iso), exposureSeconds=\(device.exposureDuration.seconds)", category: "capture", captureID: id)
                }
                TestLog.shared.record("physicalInput=\(deviceInput?.device.isVirtualDevice == false), " +
                    "depthAtZoom=\(currentDepthSupported)", category: "capture", captureID: id)
                photoOutput.capturePhoto(with: settings, delegate: self)

                sessionQueue.asyncAfter(deadline: .now() + DepthCapturePolicy.captureTimeout) { [weak self] in
                    guard let self, self.pendingCapture?.id == id else { return }
                    TestLog.shared.record("timed out after \(DepthCapturePolicy.captureTimeout)s; restarting capture session", category: "capture", captureID: id)
                    // 迟到回调由 uniqueID 丢弃；重启在同一队列，下一次请求不会插入重启中间。
                    if self.session.isRunning { self.session.stopRunning() }
                    self.finishCapture(id: id, result: .failure(CameraError.captureTimedOut))
                    if self.wantsToRun && !self.session.isInterrupted {
                        self.session.startRunning()
                        self.eventHandler?(.ready(self.makeState()))
                    }
                }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        TestLog.shared.record("processing callback error=\(error.map(TestLog.errorDescription) ?? "none")", category: "capture", captureID: id)
        let hasDepth = photo.depthData != nil
        let data = error == nil ? photo.fileDataRepresentation() : nil
        // 关键修订：把“本张照片的深度值”交给渲染器，而不是只交一个 hasDepth 布尔值。
        var snapshot: NativeDepthSnapshot?
        var depthIssue: String?
        if error == nil, let depth = photo.depthData {
            do { snapshot = try NativeDepthSnapshot(depthData: depth) }
            catch { depthIssue = error.localizedDescription }
        }
        let frozenSnapshot = snapshot
        let frozenIssue = depthIssue
        // 同帧遮罩复制为值后跨队列传递；不把 CVPixelBuffer 或选区保存进成片。
        let frozenMatte = error == nil ? photo.portraitEffectsMatte.flatMap { matte -> NativePortraitMatteSnapshot? in
            do { return try NativePortraitMatteSnapshot(portraitEffectsMatte: matte) }
            catch {
                TestLog.shared.record("native matte copy failed: \(TestLog.errorDescription(error))", category: "capture", captureID: id)
                return nil
            }
        } : nil
        TestLog.shared.record("delivered bytes=\(data?.count ?? 0), depth=\(hasDepth), copiedDepth=\(frozenSnapshot != nil), depthCopyError=\(frozenIssue ?? "none"), matteDelivered=\(photo.portraitEffectsMatte != nil), matteCopied=\(frozenMatte != nil)", category: "capture", captureID: id)
        let sourceType = photo.sourceDeviceType?.rawValue ?? "unknown"
        TestLog.shared.record("photo sourceDeviceType=\(sourceType), deliveredDepth=\(hasDepth)", category: "capture", captureID: id)
        sessionQueue.async { [self] in
            guard let pending = pendingCapture, pending.id == id else { return }
            if let error {
                pending.result = .failure(error)
            } else if let data {
                let summary = "captureID=\(id)\nsource=\(sourceType)\nrequestedDepth=\(pending.depthRequested)" +
                    "\ndeliveredDepth=\(hasDepth)\ndirectDepthCopy=\(frozenSnapshot != nil)" +
                    "\ndepthCopyIssue=\(frozenIssue ?? "none")" +
                    "\nnativePortraitMatte=\(frozenMatte != nil)"
                TestLog.shared.record("[Capture \(id)] photoBytes=\(data.count), depth=\(hasDepth), directCopy=\(frozenSnapshot != nil)")
                pending.result = .success(CapturedPhoto(data: data, depthRequested: pending.depthRequested,
                    hasDepthData: hasDepth, nativeDepth: frozenSnapshot, options: pending.options,
                    transientDeviceFocus: pending.transientDeviceFocus, captureSummary: summary,
                    nativePortraitMatte: frozenMatte, captureID: id))
            } else {
                pending.result = .failure(CameraError.captureFailed)
            }
        }
    }

    /// 等完整拍摄结束才恢复 continuation，不在 processing 回调抢先停止相机。
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        sessionQueue.async { [self] in
            let id = resolvedSettings.uniqueID
            TestLog.shared.record("terminal callback error=\(error.map(TestLog.errorDescription) ?? "none")", category: "capture", captureID: id)
            guard let pending = pendingCapture, pending.id == id else { return }
            if let error {
                finishCapture(id: id, result: .failure(error))
            } else {
                finishCapture(id: id, result: pending.result ?? .failure(CameraError.captureFailed))
            }
        }
    }

    // MARK: - Session-queue-only helpers

    private func onSessionQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do { continuation.resume(returning: try work()) }
                catch {
                    TestLog.shared.record("session operation failed: \(TestLog.errorDescription(error))", category: "camera")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureSession(for target: AVCaptureDevice.Position, rearLensID: String? = nil,
                                  rawZoom: Double? = nil) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let device: AVCaptureDevice
        let requestedRawZoom: Double
        if target == .back {
            // 只发现三种物理 RGB 镜头，虚拟双摄、三摄和 LiDAR 组合不参与选择。
            let physicalTypes: [AVCaptureDevice.DeviceType] = [
                .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera
            ]
            let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: physicalTypes,
                mediaType: .video, position: .back).devices
            let candidates = discovered.compactMap { device -> CameraLensCandidate? in
                guard let kind = physicalLensKind(for: device.deviceType) else { return nil }
                return CameraLensCandidate(id: device.uniqueID, kind: kind, isVirtual: device.isVirtualDevice)
            }
            rearLensOptions = CameraLensPolicy.options(candidates: candidates)
            guard let choice = CameraLensPolicy.select(requestedID: rearLensID ?? selectedRearDeviceID,
                                                       options: rearLensOptions),
                  let physical = discovered.first(where: { $0.uniqueID == choice.id }),
                  !physical.isVirtualDevice else { throw CameraError.unavailable }
            device = physical
            requestedRawZoom = rawZoom ?? rearRawZoom
        } else {
            guard let front = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                throw CameraError.unavailable
            }
            device = front
            requestedRawZoom = 1
        }
        // 先解析并创建指定输入，失败时不能改用另一颗镜头。
        let input = try AVCaptureDeviceInput(device: device)
        TestLog.shared.record("configure start position=\(target.rawValue), " +
            "deviceType=\(device.deviceType.rawValue), isVirtual=\(device.isVirtualDevice)", category: "camera")
        isConfigured = false
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        disableDepthDelivery()
        if let deviceInput { session.removeInput(deviceInput) }
        deviceInput = nil
        session.sessionPreset = .photo
        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
            session.addOutput(photoOutput)
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)
        deviceInput = input

        // 仅使用这颗物理镜头本身的能力；没有深度时保持它进行普通拍照。
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        let preferred = dimensions.last(where: {
            Int64($0.width) * Int64($0.height) <= DepthCapturePolicy.preferredPhotoPixelCount
        }) ?? dimensions.first
        if let preferred { photoOutput.maxPhotoDimensions = preferred }

        try applyZoom(requestedRawZoom, to: device)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        userDidTapFocus = false
        position = target
        if target == .back { selectedRearDeviceID = device.uniqueID }
        isConfigured = true
        TestLog.shared.record("[Camera] configured physical=\(!device.isVirtualDevice), depth=\(currentDepthSupported), " +
            "digitalZoom=\(device.videoZoomFactor), " +
            "available=[\(device.minAvailableVideoZoomFactor), \(device.maxAvailableVideoZoomFactor)], " +
            "photo=\(photoOutput.maxPhotoDimensions.width)x\(photoOutput.maxPhotoDimensions.height)", category: "camera")
    }

    private func physicalLensKind(for type: AVCaptureDevice.DeviceType) -> CameraLensKind? {
        switch type {
        case .builtInUltraWideCamera: return .ultraWide
        case .builtInWideAngleCamera: return .wide
        case .builtInTelephotoCamera: return .telephoto
        default: return nil
        }
    }

    private func depthZoomRanges(for device: AVCaptureDevice) -> [ClosedRange<Double>] {
        if #available(iOS 17.2, *) {
            return device.activeFormat.supportedVideoZoomRangesForDepthDataDelivery.map {
                Double($0.lowerBound)...Double($0.upperBound)
            }
        }
        return device.activeFormat.supportedVideoZoomFactorsForDepthDataDelivery.map {
            Double($0)...Double($0)
        }
    }

    private func zoomPlan(_ rawZoom: Double, for device: AVCaptureDevice) -> CameraZoomPlan {
        CameraZoomPolicy.plan(requestedRawZoom: rawZoom,
            maximumRawZoom: Double(device.activeFormat.videoMaxZoomFactor), displayMultiplier: 1,
            depthAvailable: photoOutput.isDepthDataDeliverySupported,
            depthRanges: depthZoomRanges(for: device))
    }

    private var currentDepthSupported: Bool {
        guard let device = deviceInput?.device, photoOutput.isDepthDataDeliveryEnabled else { return false }
        return zoomPlan(Double(device.videoZoomFactor), for: device).depthEnabled
    }

    private func disableDepthDelivery() {
        photoOutput.enabledSemanticSegmentationMatteTypes = []
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
        photoOutput.isDepthDataDeliveryEnabled = false
    }

    /// 调用方已在 sessionQueue 的配置事务中。非法深度倍率先关闭深度，再数码变焦。
    private func applyZoom(_ requested: Double, to device: AVCaptureDevice) throws {
        let plan = zoomPlan(requested, for: device)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if photoOutput.isDepthDataDeliveryEnabled && !plan.depthEnabled { disableDepthDelivery() }
        device.videoZoomFactor = CGFloat(plan.rawZoomFactor)
        if plan.depthEnabled && !photoOutput.isDepthDataDeliveryEnabled {
            photoOutput.isDepthDataDeliveryEnabled = true
        }
        // 深度配置若改变数码倍率，优先保留用户构图并显示普通拍照状态。
        if abs(Double(device.videoZoomFactor) - plan.rawZoomFactor) > 0.000_001 {
            disableDepthDelivery()
            device.videoZoomFactor = CGFloat(plan.rawZoomFactor)
        }
        let depthEnabled = photoOutput.isDepthDataDeliveryEnabled
        let portraitEnabled = depthEnabled && photoOutput.isPortraitEffectsMatteDeliverySupported
        if photoOutput.isPortraitEffectsMatteDeliveryEnabled != portraitEnabled {
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = portraitEnabled
        }
        let wantedMattes: [AVSemanticSegmentationMatte.MatteType] = [.hair, .glasses]
        let mattes = depthEnabled
            ? photoOutput.availableSemanticSegmentationMatteTypes.filter { wantedMattes.contains($0) } : []
        if photoOutput.enabledSemanticSegmentationMatteTypes != mattes {
            photoOutput.enabledSemanticSegmentationMatteTypes = mattes
        }
        userDidTapFocus = false
        if device.position == .back { rearRawZoom = Double(device.videoZoomFactor) }
    }

    private func makeState() -> CameraState {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let device = deviceInput?.device
        let lens = rearLensOptions.first { $0.id == device?.uniqueID }
        return CameraState(isFront: position == .front, hasFlash: device?.hasFlash ?? false,
            depthSupported: currentDepthSupported, zoomFactor: device?.videoZoomFactor ?? 1,
            isRunning: session.isRunning && !session.isInterrupted, deviceName: device?.localizedName ?? "",
            rearLensOptions: position == .back ? rearLensOptions : [],
            selectedRearLensID: position == .back ? lens?.id : nil,
            activeLensName: position == .front ? "前置" : (lens?.title ?? "后置"))
    }

    private func finishCapture(id: Int64, result: Result<CapturedPhoto, Error>) {
        guard let pending = pendingCapture, pending.id == id else { return }
        pendingCapture = nil
        switch result {
        case .success: TestLog.shared.record("capture completed; handing photo to renderer", category: "capture", captureID: id)
        case .failure(let error): TestLog.shared.record("capture failed: \(TestLog.errorDescription(error))", category: "capture", captureID: id)
        }
        pending.continuation.resume(with: result)
    }

    private func installSessionObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            TestLog.shared.record("session interrupted reason=\(reason)", category: "camera")
            self.sessionQueue.async {
                if let pending = self.pendingCapture {
                    self.finishCapture(id: pending.id, result: .failure(CameraError.interrupted))
                }
                self.eventHandler?(.interrupted)
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                TestLog.shared.record("session interruption ended wantsToRun=\(self.wantsToRun)", category: "camera")
                guard self.wantsToRun else { return }
                if !self.session.isRunning { self.session.startRunning() }
                self.eventHandler?(.ready(self.makeState()))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let reset = error?.code == AVError.Code.mediaServicesWereReset.rawValue
            let message = error?.localizedDescription ?? CameraError.unavailable.localizedDescription
            self.sessionQueue.async {
                TestLog.shared.record("runtime error: \(error.map(TestLog.errorDescription) ?? message), mediaServicesReset=\(reset)", category: "camera")
                if let pending = self.pendingCapture {
                    self.finishCapture(id: pending.id, result: .failure(CameraError.interrupted))
                }
                if reset && self.wantsToRun {
                    if !self.session.isRunning { self.session.startRunning() }
                    self.eventHandler?(.ready(self.makeState()))
                } else {
                    self.eventHandler?(.issue(message))
                }
            }
        })
    }
}
