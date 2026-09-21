//
//  CameraManager.swift
//  TestCamer
//
//  Created by Linhao-Mac on 2026/9/21.
//  在原 Demo 上修改：普通预览 + 单次拍照深度，不建立实时图像/深度处理链。
//

import Foundation
@preconcurrency import AVFoundation

// 工程不再默认把所有类型隔离到 MainActor；相机可变状态只在 sessionQueue 访问。
/// 传给 UI 的不可变快照。UI 不再直接跨线程读取 deviceInput / zoomFactor。
struct CameraState: Sendable {
    let isFront: Bool
    let hasFlash: Bool
    let depthSupported: Bool
    let zoomFactor: CGFloat
    let isRunning: Bool
    let deviceName: String
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
    private var depthFocusPoint: CGPoint?
    private var eventHandler: (@Sendable (CameraEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []

    private final class PendingCapture {
        let id: Int64
        let options: DepthOptions
        let depthRequested: Bool
        let continuation: CheckedContinuation<CapturedPhoto, Error>
        var result: Result<CapturedPhoto, Error>?

        init(id: Int64, options: DepthOptions, depthRequested: Bool,
             continuation: CheckedContinuation<CapturedPhoto, Error>) {
            self.id = id
            self.options = options
            self.depthRequested = depthRequested
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
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
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
            print("[Camera] running, device=\(deviceInput?.device.localizedName ?? "unknown")")
            return makeState()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            wantsToRun = false
            depthFocusPoint = nil
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
            let previous = position
            let next: AVCaptureDevice.Position = previous == .back ? .front : .back
            let restart = wantsToRun
            if session.isRunning { session.stopRunning() }
            do {
                try configureSession(for: next)
            } catch {
                // 不能因为切换失败把原来的输入永远移除，留下黑屏。
                print("[Camera] switch failed: \(error); restoring previous input")
                try? configureSession(for: previous)
                if restart && isConfigured { session.startRunning() }
                throw error
            }
            if restart { session.startRunning() }
            return makeState()
        }
    }

    /// 高频手势不为每帧创建 Task。更新和拍照请求仍在同一串行队列执行。
    func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [self] in
            guard pendingCapture == nil, let device = deviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.videoZoomFactor = CGFloat(DepthCapturePolicy.clampedZoom(
                    Double(factor), minimum: Double(device.minAvailableVideoZoomFactor),
                    maximum: Double(device.maxAvailableVideoZoomFactor)))
                eventHandler?(.ready(makeState()))
            } catch {
                print("[Camera] zoom rejected: \(error.localizedDescription)")
            }
        }
    }

    /// 点按同时指定下一张照片的景深清晰区域；只在内存中传递，不写入照片或日志。
    func focus(at point: CGPoint) {
        sessionQueue.async { [self] in
            guard pendingCapture == nil, let device = deviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                depthFocusPoint = point
                print("[Camera] hardware autofocus and next-photo depth focus requested")
            } catch {
                print("[Camera] focus rejected: \(error.localizedDescription)")
            }
        }
    }

    func capturePhoto(flashMode: AVCaptureDevice.FlashMode, options: DepthOptions,
                      rotationAngle: CGFloat, mirrored: Bool) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard pendingCapture == nil else {
                    continuation.resume(throwing: CameraError.busy)
                    return
                }
                guard session.isRunning, !session.isInterrupted,
                      let connection = photoOutput.connection(with: .video) else {
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
                let useDepth = options.enabled && photoOutput.isDepthDataDeliverySupported
                    && photoOutput.isDepthDataDeliveryEnabled
                settings.isDepthDataDeliveryEnabled = useDepth
                settings.isDepthDataFiltered = true
                settings.embedsDepthDataInPhoto = useDepth
                settings.isPortraitEffectsMatteDeliveryEnabled = useDepth
                    && photoOutput.isPortraitEffectsMatteDeliveryEnabled
                settings.embedsPortraitEffectsMatteInPhoto = settings.isPortraitEffectsMatteDeliveryEnabled

                let id = settings.uniqueID
                let frozenOptions = DepthOptions(enabled: options.enabled, aperture: options.aperture,
                                                 focusPoint: depthFocusPoint)
                depthFocusPoint = nil
                pendingCapture = PendingCapture(id: id, options: frozenOptions, depthRequested: useDepth,
                                                continuation: continuation)
                print("[Capture \(id)] depthRequested=\(useDepth), virtual f/\(options.aperture), angle=\(rotationAngle)")
                photoOutput.capturePhoto(with: settings, delegate: self)

                sessionQueue.asyncAfter(deadline: .now() + DepthCapturePolicy.captureTimeout) { [weak self] in
                    guard let self, self.pendingCapture?.id == id else { return }
                    print("[Capture \(id)] timed out; restarting capture session")
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
        let hasDepth = photo.depthData != nil
        let data = error == nil ? photo.fileDataRepresentation() : nil
        sessionQueue.async { [self] in
            guard let pending = pendingCapture, pending.id == id else { return }
            if let error {
                pending.result = .failure(error)
            } else if let data {
                print("[Capture \(id)] photoBytes=\(data.count), deliveredDepth=\(hasDepth)")
                pending.result = .success(CapturedPhoto(data: data, depthRequested: pending.depthRequested,
                                                        hasDepthData: hasDepth, options: pending.options))
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
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func configureSession(for target: AVCaptureDevice.Position) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        isConfigured = false
        depthFocusPoint = nil
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        if let deviceInput { session.removeInput(deviceInput) }
        deviceInput = nil
        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
            session.addOutput(photoOutput)
        }
        photoOutput.maxPhotoQualityPrioritization = .quality

        // 不根据机型名称硬编码“支持”。逐个接入原生相机，用当前 photoOutput 的实际能力判定。
        let types: [AVCaptureDevice.DeviceType] = target == .front
            ? [.builtInTrueDepthCamera]
            : [.builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera, .builtInLiDARDepthCamera]
        for type in types {
            guard let device = AVCaptureDevice.default(type, for: .video, position: target),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { continue }
            session.addInput(input)
            let supported = photoOutput.isDepthDataDeliverySupported
            print("[Capability] \(device.localizedName), type=\(type.rawValue), photoDepth=\(supported)")
            if supported {
                deviceInput = input
                break
            }
            session.removeInput(input)
        }
        if deviceInput == nil {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                throw CameraError.unavailable
            }
            session.addInput(input)
            deviceInput = input
            print("[Capability] native depth unavailable; ordinary photo fallback")
        }
        guard let device = deviceInput?.device else { throw CameraError.configurationFailed }
        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = true
        } else {
            photoOutput.isDepthDataDeliveryEnabled = false
        }
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled
            && photoOutput.isPortraitEffectsMatteDeliverySupported

        // 使用当前格式真实支持的尺寸，优先约 12 MP，避免默认去做 48 MP 大内存景深渲染。
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        let preferred = dimensions.last(where: {
            Int64($0.width) * Int64($0.height) <= DepthCapturePolicy.preferredPhotoPixelCount
        }) ?? dimensions.first
        if let preferred { photoOutput.maxPhotoDimensions = preferred }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        // Dual-wide 的虚拟 1x 可能是超广角；优先切换点，并始终尊重系统的深度模式变焦范围。
        let desiredZoom = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1
        device.videoZoomFactor = CGFloat(DepthCapturePolicy.clampedZoom(
            desiredZoom, minimum: Double(device.minAvailableVideoZoomFactor),
            maximum: Double(device.maxAvailableVideoZoomFactor)))
        position = target
        isConfigured = true
        print("[Camera] configured depth=\(photoOutput.isDepthDataDeliveryEnabled), " +
              "zoom=\(device.videoZoomFactor), available=[\(device.minAvailableVideoZoomFactor), \(device.maxAvailableVideoZoomFactor)], " +
              "photo=\(photoOutput.maxPhotoDimensions.width)x\(photoOutput.maxPhotoDimensions.height)")
    }

    private func makeState() -> CameraState {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        return CameraState(isFront: position == .front, hasFlash: deviceInput?.device.hasFlash ?? false,
                           depthSupported: photoOutput.isDepthDataDeliverySupported && photoOutput.isDepthDataDeliveryEnabled,
                           zoomFactor: deviceInput?.device.videoZoomFactor ?? 1,
                           isRunning: session.isRunning && !session.isInterrupted,
                           deviceName: deviceInput?.device.localizedName ?? "")
    }

    private func finishCapture(id: Int64, result: Result<CapturedPhoto, Error>) {
        guard let pending = pendingCapture, pending.id == id else { return }
        pendingCapture = nil
        pending.continuation.resume(with: result)
    }

    private func installSessionObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
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
                print("[Camera] runtime error: \(message)")
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
