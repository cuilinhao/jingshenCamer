//
//  ViewController.swift
//  TestCamer
//
//  Created by Linhao-Mac on 2026/9/21.
//

import Photos
import UIKit
import AVFoundation

@MainActor
final class ViewController: UIViewController {
    private let camera = CameraManager()
    private var flashMode: AVCaptureDevice.FlashMode = .off
    private var isCapturing = false
    private var lastZoomFactor: CGFloat = 1
    private var capturedImage: UIImage?
    private var originalComparisonImage: UIImage?
    private var legacyComparisonImage: UIImage?
    private var processedPhoto: ProcessedPhoto?
    private let processor = DepthPhotoProcessor()
    private let editableStore = EditablePhotoStore()
    private let libraryButton = UIButton(type: .system)
    private var pendingEditor: PhotoEditorViewController?
    private var cameraState: CameraState?
    private var isStarting = false
    private var isSwitching = false
    private var isSaving = false
    private var isScreenVisible = false
    private var wantsDepth = true
    private var isExportingLog = false
    private let exportLogButton = UIButton(type: .system)

    private let depthPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let depthSwitch = UISwitch()
    private let depthTitleLabel = UILabel()
    private let depthHintLabel = UILabel()
    private let apertureSlider = UISlider()
    private let apertureLabel = UILabel()
    private let resultInfoLabel = UILabel()
    private let compareButton = UIButton(type: .system)
    private let legacyCompareButton = UIButton(type: .system)
    private let diagnosticsButton = UIButton(type: .system)
    private let comparisonControls = UIStackView()
    private let retryButton = UIButton(type: .system)
    private let processingSpinner = UIActivityIndicatorView(style: .large)

    private let previewView = UIView()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let dimView = UIView()
    private let capturedImageView = UIImageView()
    private let statusLabel = UILabel()
    private let flashButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private let shutterButton = UIButton(type: .custom)
    private let retakeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let cameraControls = UIStackView()
    private let rearLensContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let rearLensStack = UIStackView()
    private var displayedLensOptions: [CameraLensOption] = []
    private var rearLensButtons: [String: UIButton] = [:]
    private let resultControls = UIStackView()
    private let focusIndicator = UIView()

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configurePreviewLayer()
        setupUI()
        TestLog.shared.record("camera screen loaded", category: "ui")
        camera.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in self?.handleCameraEvent(event) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                                name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                                name: UIApplication.didEnterBackgroundNotification, object: nil)
        updateControlAvailability()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        TestLog.shared.record("memory warning isCapturing=\(isCapturing), hasResult=\(processedPhoto != nil)", category: "app")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = previewView.bounds
        updatePreviewOrientation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isScreenVisible = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentPendingEditor()
        Task { await startCamera() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isScreenVisible = false
        camera.stop()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { _ in
            self.updatePreviewOrientation()
        }
    }

    private func configurePreviewLayer() {
        previewLayer.session = camera.session
        previewLayer.videoGravity = .resizeAspectFill
        previewView.layer.insertSublayer(previewLayer, at: 0)
    }

    private func startCamera() async {
        guard isScreenVisible, capturedImage == nil, !isStarting, !isCapturing, !isSwitching,
              UIApplication.shared.applicationState != .background else { return }
        TestLog.shared.record("start camera requested", category: "ui")
        isStarting = true
        statusLabel.isHidden = false
        statusLabel.text = "正在开启相机…"
        retryButton.isHidden = true
        updateControlAvailability()
        defer { isStarting = false; updateControlAvailability() }
        do {
            try await camera.prepare()
            guard isScreenVisible, capturedImage == nil,
                  UIApplication.shared.applicationState != .background else { return }
            cameraState = try await camera.start()
            guard isScreenVisible, UIApplication.shared.applicationState != .background else {
                camera.stop()
                return
            }
            updatePreviewOrientation()
            updateFlashButton()
            updateDepthPanel()
            statusLabel.isHidden = true
        } catch {
            showCameraUnavailable(error)
        }
    }

    @objc private func appDidBecomeActive() {
        presentPendingEditor()
        Task { await startCamera() }
    }

    @objc private func appDidEnterBackground() {
        camera.stop()
        cameraState = nil
        updateControlAvailability()
    }

    @objc private func retryCameraTapped() { Task { await startCamera() } }

    private func handleCameraEvent(_ event: CameraEvent) {
        guard isScreenVisible, capturedImage == nil,
              UIApplication.shared.applicationState != .background else { return }
        switch event {
        case .ready(let state):
            cameraState = state
            if state.isRunning && !isCapturing {
                statusLabel.isHidden = true
                retryButton.isHidden = true
            }
            updateDepthPanel()
            updatePreviewOrientation()
        case .interrupted:
            cameraState = nil
            statusLabel.isHidden = false
            statusLabel.text = "相机暂时被系统中断，恢复后可继续拍摄。"
        case .issue(let message):
            cameraState = nil
            statusLabel.isHidden = false
            statusLabel.text = message
            retryButton.isHidden = false
        }
        updateControlAvailability()
    }

    private func showCameraUnavailable(_ error: Error) {
        TestLog.shared.record("camera unavailable: \(TestLog.errorDescription(error))", category: "ui")
        statusLabel.isHidden = false
        statusLabel.text = error.localizedDescription
        cameraState = nil
        retryButton.isHidden = false
        shutterButton.isEnabled = false
        switchButton.isEnabled = false
        flashButton.isEnabled = false

        if let cameraError = error as? CameraError, cameraError == .notAuthorized {
            presentSettingsAlert()
        }
    }

    private func presentSettingsAlert() {
        let alert = UIAlertController(
            title: "需要相机权限",
            message: "请在设置中允许 TestCamer 访问相机。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        present(alert, animated: true)
    }
}

// MARK: - Actions

private extension ViewController {
    @objc func exportTestLog() {
        guard !isExportingLog, !isCapturing, !isStarting, !isSwitching, presentedViewController == nil else { return }
        isExportingLog = true
        updateControlAvailability()
        exportLogButton.isEnabled = false
        exportLogButton.configuration?.title = "正在导出…"
        TestLog.shared.record("export requested", category: "log")
        Task {
            defer {
                isExportingLog = false
                exportLogButton.isEnabled = true
                exportLogButton.configuration?.title = "导出 TestLog"
                updateControlAvailability()
            }
            do {
                let file = try await Task.detached(priority: .utility) {
                    try TestLog.shared.export()
                }.value
                guard view.window != nil, presentedViewController == nil,
                      UIApplication.shared.applicationState == .active else {
                    TestLog.shared.record("export prepared; share sheet unavailable because screen is inactive", category: "log")
                    return
                }
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = exportLogButton
                share.popoverPresentationController?.sourceRect = exportLogButton.bounds
                share.completionWithItemsHandler = { _, completed, _, error in
                    TestLog.shared.record("share completed=\(completed), error=\(error.map(TestLog.errorDescription) ?? "none")", category: "log")
                }
                present(share, animated: true)
            } catch {
                TestLog.shared.record("export failed: \(TestLog.errorDescription(error))", category: "log")
                presentAlert(title: "日志导出失败", message: error.localizedDescription)
            }
        }
    }

    func preparePhotoEditor(document: EditablePhotoDocument, result: ProcessedPhoto, saveError: String?) {
        let editor = PhotoEditorViewController(document: document, store: editableStore,
            originalPreviewData: result.originalPreviewData, initialSaveError: saveError,
            captureDiagnostics: result)
        editor.onClose = { [weak self] in self?.retakeTapped() }
        pendingEditor = editor
        presentPendingEditor()
    }

    func presentPendingEditor() {
        guard let editor = pendingEditor, isScreenVisible, view.window != nil,
              UIApplication.shared.applicationState == .active, presentedViewController == nil else { return }
        pendingEditor = nil
        let navigation = UINavigationController(rootViewController: editor)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    @objc func showEditableLibrary() {
        guard !isCapturing, !isSaving, !isStarting, !isSwitching, !isExportingLog, presentedViewController == nil else { return }
        let library = EditablePhotoLibraryViewController(store: editableStore)
        let navigation = UINavigationController(rootViewController: library)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    @objc func captureTapped() {
        guard !isCapturing, !isSwitching, !isStarting, !isExportingLog, cameraState?.isRunning == true else {
            TestLog.shared.record("shutter ignored capturing=\(isCapturing), switching=\(isSwitching), starting=\(isStarting), running=\(cameraState?.isRunning == true)", category: "ui")
            return
        }
        TestLog.shared.record("shutter tapped", category: "ui")
        // 快门时冻结 f 值、景深开关、方向。异步过程中后来的 UI 变化不影响这张照片。
        let options = DepthOptions(enabled: wantsDepth,
                                   aperture: DepthCapturePolicy.aperture(sliderValue: apertureSlider.value))
        let rotation = previewRotationAngle
        let mirrored = cameraState?.isFront == true
        isCapturing = true
        retryButton.isHidden = true
        updateControlAvailability()
        processingSpinner.startAnimating()
        statusLabel.isHidden = false
        statusLabel.text = "正在拍摄…"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashScreen()

        Task {
            defer {
                isCapturing = false
                processingSpinner.stopAnimating()
                updateControlAvailability()
            }
            do {
                let payload = try await camera.capturePhoto(flashMode: flashMode, options: options,
                                                           rotationAngle: rotation, mirrored: mirrored)
                statusLabel.text = options.enabled
                    ? (payload.prefersAppleDepth && payload.hasDepthData ? "正在生成苹果景深…" : "正在生成智能景深…")
                    : "正在生成照片…"
                let result = try await processor.process(payload)
                guard let image = UIImage(data: result.previewData) else { throw CameraError.captureFailed }
                TestLog.shared.record("result displayed outcome=\(result.outcome.rawValue), dimensions=\(result.pixelWidth)x\(result.pixelHeight)", category: "ui", captureID: result.captureID)
                processedPhoto = result
                originalComparisonImage = UIImage(data: result.originalPreviewData)
                legacyComparisonImage = result.legacyComparison.flatMap {
                    $0.outcome.canCompare ? UIImage(data: $0.previewData) : nil
                }
                statusLabel.isHidden = true
                showCapturedImage(image)
                if let recipe = result.editRecipe {
                    let document = EditablePhotoDocument(sourceData: payload.data, initialRecipe: recipe,
                        recipe: recipe, previewData: result.previewData, depthData: result.editDepthData,
                        renderingInfo: PhotoRenderingInfo(appleFallbackReason: result.appleFallbackReason,
                            usedAppleMetadataCompatibility: result.usedAppleMetadataCompatibility))
                    var saveError: String?
                    do { try await editableStore.save(document) }
                    catch { saveError = error.localizedDescription }
                    preparePhotoEditor(document: document, result: result, saveError: saveError)
                }
            } catch {
                cameraState = try? await camera.currentState()
                statusLabel.isHidden = cameraState?.isRunning == true
                if !statusLabel.isHidden {
                    statusLabel.text = error.localizedDescription
                    retryButton.isHidden = false
                }
                presentError(error)
            }
        }
    }

    @objc func switchTapped() {
        guard !isCapturing, !isSwitching, !isStarting, !isExportingLog,
              capturedImage == nil, cameraState?.isRunning == true else { return }
        isSwitching = true
        updateControlAvailability()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            defer {
                isSwitching = false
                lastZoomFactor = cameraState?.zoomFactor ?? 1
                updatePreviewOrientation()
                updateControlAvailability()
            }
            do {
                cameraState = try await camera.switchCamera()
            } catch {
                cameraState = try? await camera.currentState()
                presentError(error)
            }
        }
    }

    func selectRearLens(id: String) {
        guard !isCapturing, !isSwitching, !isStarting, !isExportingLog, capturedImage == nil,
              let state = cameraState, state.isRunning, !state.isFront,
              state.rearLensOptions.contains(where: { $0.id == id }) else { return }
        isSwitching = true
        updateControlAvailability()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            defer {
                isSwitching = false
                lastZoomFactor = cameraState?.zoomFactor ?? 1
                updatePreviewOrientation()
                updateControlAvailability()
            }
            do {
                cameraState = try await camera.selectRearLens(id: id)
            } catch {
                cameraState = try? await camera.currentState()
                presentError(error)
            }
        }
    }

    @objc func flashTapped() {
        switch flashMode {
        case .off: flashMode = .on
        case .on: flashMode = .auto
        default: flashMode = .off
        }
        updateFlashButton()
    }

    @objc func retakeTapped() {
        guard !isSaving else { return }
        TestLog.shared.record("retake requested", category: "ui", captureID: processedPhoto?.captureID)
        pendingEditor = nil
        capturedImage = nil
        originalComparisonImage = nil
        legacyComparisonImage = nil
        processedPhoto = nil
        capturedImageView.image = nil
        capturedImageView.isHidden = true
        resultControls.isHidden = true
        resultInfoLabel.isHidden = true
        compareButton.isHidden = true
        comparisonControls.isHidden = true
        cameraControls.isHidden = false
        depthPanel.isHidden = false
        cameraState = nil
        updateControlAvailability()
        Task { await startCamera() }
    }

    @objc func saveTapped() {
        guard let photo = processedPhoto, !isSaving else { return }
        TestLog.shared.record("save requested bytes=\(photo.jpegData.count), outcome=\(photo.outcome.rawValue)", category: "save", captureID: photo.captureID)
        isSaving = true
        endComparison()
        updateControlAvailability()
        Task {
            defer { isSaving = false; updateControlAvailability() }
            do {
                // 保存的是完整分辨率的编码成片，不是 UIImageView 里的预览缩略图。
                // 即使按住“看原图”时点击保存，也不会误保存普通原图。
                try await saveToPhotoLibrary(photo.jpegData)
                TestLog.shared.record("saved to photo library", category: "save", captureID: photo.captureID)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                presentAlert(title: "已保存", message: "\(photo.outcome.message)已保存到相册。\n不包含可重编辑的聚焦位置。")
            } catch {
                presentError(error)
            }
        }
    }

    @objc func depthSwitchChanged() {
        wantsDepth = depthSwitch.isOn
        TestLog.shared.record("depth enabled=\(wantsDepth)", category: "ui")
        updateDepthPanel()
    }

    @objc func apertureChanged() {
        apertureSlider.value = apertureSlider.value.rounded()
        updateDepthPanel() // 仅更新下一次拍照参数；不渲染预览。
    }

    @objc func beginComparison() {
        guard !isSaving, processedPhoto?.outcome.canCompare == true else { return }
        capturedImageView.image = originalComparisonImage
        let rendererTitle = processedPhoto?.rendererTitle ?? "当前效果"
        resultInfoLabel.text = "原图 · 松开恢复\(rendererTitle)\n同一次快门 · 未添加景深虚化"
        legacyCompareButton.isEnabled = false
    }

    @objc func beginLegacyComparison() {
        guard !isSaving, let image = legacyComparisonImage else { return }
        capturedImageView.image = image
        resultInfoLabel.text = "旧版对比 · 松开恢复当前成片\n同一次快门 · 相同光圈与选焦"
        compareButton.isEnabled = false
    }

    @objc func endComparison() {
        capturedImageView.image = capturedImage
        compareButton.configuration?.title = "按住看原图"
        updateResultDescription()
        updateControlAvailability()
    }

    @objc func showDepthDiagnostics() {
        guard let photo = processedPhoto, !isSaving, presentedViewController == nil else { return }
        endComparison()
        let comparison = photo.legacyComparison.map { "\n\n同帧旧版结果：\($0.outcome.message)" } ?? ""
        let screen = DepthDiagnosticsViewController(text: photo.diagnosticText + comparison,
            maskData: photo.diagnosticMaskData, isOutputDifference: photo.diagnosticImageIsDifference)
        let navigation = UINavigationController(rootViewController: screen)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        present(navigation, animated: true)
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard capturedImage == nil, !isCapturing, !isSwitching, !isStarting, !isExportingLog,
              cameraState?.isRunning == true else { return }
        if gesture.state == .began {
            lastZoomFactor = cameraState?.zoomFactor ?? 1
        }
        camera.setZoomFactor(lastZoomFactor * gesture.scale)
    }

    @objc func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard capturedImage == nil, !isCapturing, !isSwitching, cameraState?.isRunning == true else { return }
        let location = gesture.location(in: previewView)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        camera.focus(at: devicePoint)
        showFocusIndicator(at: location)
    }
}

// MARK: - UI

private extension ViewController {
    func setupUI() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        previewView.clipsToBounds = true
        view.addSubview(previewView)

        capturedImageView.translatesAutoresizingMaskIntoConstraints = false
        capturedImageView.contentMode = .scaleAspectFit // 成片完整显示，不裁掉照片边缘。
        capturedImageView.clipsToBounds = true
        capturedImageView.isHidden = true
        capturedImageView.backgroundColor = .black
        view.addSubview(capturedImageView)

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        dimView.alpha = 0
        dimView.isUserInteractionEnabled = false
        view.addSubview(dimView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        view.addSubview(statusLabel)

        configureIconButton(flashButton, systemName: "bolt.slash.fill", action: #selector(flashTapped))
        flashButton.accessibilityLabel = "闪光灯"
        configureIconButton(switchButton, systemName: "camera.rotate.fill", action: #selector(switchTapped))
        switchButton.accessibilityLabel = "切换摄像头"

        configureShutterButton()
        configureTextButton(retakeButton, title: "重拍", action: #selector(retakeTapped))
        configureTextButton(saveButton, title: "保存到相册", action: #selector(saveTapped), emphasized: true)

        cameraControls.axis = .horizontal
        cameraControls.alignment = .center
        cameraControls.distribution = .equalSpacing
        cameraControls.translatesAutoresizingMaskIntoConstraints = false
        cameraControls.addArrangedSubview(flashButton)
        cameraControls.addArrangedSubview(shutterButton)
        cameraControls.addArrangedSubview(switchButton)
        view.addSubview(cameraControls)
        setupRearLensControls()

        resultControls.axis = .horizontal
        resultControls.alignment = .center
        resultControls.distribution = .fillEqually
        resultControls.spacing = 16
        resultControls.translatesAutoresizingMaskIntoConstraints = false
        resultControls.isHidden = true
        resultControls.addArrangedSubview(retakeButton)
        resultControls.addArrangedSubview(saveButton)
        view.addSubview(resultControls)
        var logConfig = UIButton.Configuration.filled()
        logConfig.title = "导出 TestLog"
        logConfig.image = UIImage(systemName: "square.and.arrow.up")
        logConfig.imagePadding = 6
        logConfig.baseForegroundColor = .white
        logConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        logConfig.cornerStyle = .capsule
        logConfig.buttonSize = .small
        exportLogButton.configuration = logConfig
        exportLogButton.accessibilityIdentifier = "exportTestLog"
        exportLogButton.translatesAutoresizingMaskIntoConstraints = false
        exportLogButton.addTarget(self, action: #selector(exportTestLog), for: .touchUpInside)
        view.addSubview(exportLogButton)
        var libraryConfig = UIButton.Configuration.filled()
        libraryConfig.title = "可编辑照片"
        libraryConfig.image = UIImage(systemName: "photo.on.rectangle")
        libraryConfig.imagePadding = 5
        libraryConfig.baseForegroundColor = .white
        libraryConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        libraryConfig.cornerStyle = .capsule
        libraryConfig.buttonSize = .small
        libraryButton.configuration = libraryConfig
        libraryButton.accessibilityIdentifier = "editablePhotoLibrary"
        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        libraryButton.addTarget(self, action: #selector(showEditableLibrary), for: .touchUpInside)
        view.addSubview(libraryButton)
        setupDepthControls()

        focusIndicator.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        focusIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        focusIndicator.layer.borderWidth = 1.5
        focusIndicator.alpha = 0
        focusIndicator.isUserInteractionEnabled = false
        previewView.addSubview(focusIndicator)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        previewView.addGestureRecognizer(pinch)
        previewView.addGestureRecognizer(tap)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            capturedImageView.topAnchor.constraint(equalTo: view.topAnchor),
            capturedImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            capturedImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            capturedImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            shutterButton.widthAnchor.constraint(equalToConstant: 76),
            shutterButton.heightAnchor.constraint(equalToConstant: 76),
            flashButton.widthAnchor.constraint(equalToConstant: 48),
            flashButton.heightAnchor.constraint(equalToConstant: 48),
            switchButton.widthAnchor.constraint(equalToConstant: 48),
            switchButton.heightAnchor.constraint(equalToConstant: 48),

            cameraControls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 36),
            cameraControls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -36),
            cameraControls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cameraControls.heightAnchor.constraint(equalToConstant: 84),

            resultControls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            resultControls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            resultControls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            resultControls.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    func configureIconButton(_ button: UIButton, systemName: String, action: Selector) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        config.baseForegroundColor = .white
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    func configureTextButton(_ button: UIButton, title: String, action: Selector, emphasized: Bool = false) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .capsule
        config.baseForegroundColor = emphasized ? .black : .white
        config.baseBackgroundColor = emphasized ? .white : UIColor.white.withAlphaComponent(0.22)
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    func setupRearLensControls() {
        rearLensContainer.translatesAutoresizingMaskIntoConstraints = false
        rearLensContainer.layer.cornerRadius = 26
        rearLensContainer.clipsToBounds = true
        rearLensContainer.isHidden = true
        view.addSubview(rearLensContainer)

        rearLensStack.axis = .horizontal
        rearLensStack.alignment = .fill
        rearLensStack.distribution = .fillEqually
        rearLensStack.spacing = 4
        rearLensStack.translatesAutoresizingMaskIntoConstraints = false
        rearLensContainer.contentView.addSubview(rearLensStack)

        NSLayoutConstraint.activate([
            rearLensContainer.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            rearLensContainer.bottomAnchor.constraint(equalTo: cameraControls.topAnchor, constant: -14),
            rearLensContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            rearLensContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            rearLensContainer.heightAnchor.constraint(equalToConstant: 52),
            rearLensStack.topAnchor.constraint(equalTo: rearLensContainer.contentView.topAnchor, constant: 4),
            rearLensStack.leadingAnchor.constraint(equalTo: rearLensContainer.contentView.leadingAnchor, constant: 4),
            rearLensStack.trailingAnchor.constraint(equalTo: rearLensContainer.contentView.trailingAnchor, constant: -4),
            rearLensStack.bottomAnchor.constraint(equalTo: rearLensContainer.contentView.bottomAnchor, constant: -4)
        ])
    }

    func updateRearLensControls(ready: Bool) {
        let lenses = cameraState?.isFront == false ? cameraState?.rearLensOptions ?? [] : []
        if displayedLensOptions != lenses {
            for button in rearLensButtons.values {
                rearLensStack.removeArrangedSubview(button)
                button.removeFromSuperview()
            }
            rearLensButtons.removeAll()
            displayedLensOptions = lenses
            for lens in lenses {
                let button = UIButton(type: .system)
                var config = UIButton.Configuration.filled()
                config.title = lens.title
                config.cornerStyle = .capsule
                config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                    var attributes = $0
                    attributes[AttributeScopes.UIKitAttributes.FontAttribute.self] = UIFont.systemFont(ofSize: 15, weight: .semibold)
                    return attributes
                }
                button.configuration = config
                button.accessibilityIdentifier = "rearLens-\(lens.id)"
                button.accessibilityLabel = "\(lens.title)后置镜头"
                button.accessibilityHint = "选择物理镜头，再次选择可恢复原生视角"
                button.addAction(UIAction { [weak self] _ in
                    self?.selectRearLens(id: lens.id)
                }, for: .touchUpInside)
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
                rearLensStack.addArrangedSubview(button)
                rearLensButtons[lens.id] = button
            }
        }

        rearLensContainer.isHidden = capturedImage != nil || lenses.isEmpty
        for lens in lenses {
            guard let button = rearLensButtons[lens.id] else { continue }
            let selected = cameraState?.selectedRearLensID == lens.id
            button.isSelected = selected
            button.configuration?.baseForegroundColor = selected ? .black : .white
            button.configuration?.baseBackgroundColor = selected ? .systemYellow : UIColor.black.withAlphaComponent(0.25)
            button.accessibilityTraits = selected ? [.button, .selected] : .button
            button.isEnabled = ready
            button.alpha = ready ? 1 : 0.45
        }
    }

    func configureShutterButton() {
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.accessibilityLabel = "拍照"
        shutterButton.backgroundColor = .white
        shutterButton.layer.cornerRadius = 38
        shutterButton.layer.borderWidth = 4
        shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        shutterButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        shutterButton.addTarget(self, action: #selector(shutterHighlightOn), for: [.touchDown, .touchDragEnter])
        shutterButton.addTarget(self, action: #selector(shutterHighlightOff), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    @objc func shutterHighlightOn() {
        UIView.animate(withDuration: 0.08) {
            self.shutterButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
    }

    @objc func shutterHighlightOff() {
        UIView.animate(withDuration: 0.12) {
            self.shutterButton.transform = .identity
        }
    }

    func updateFlashButton() {
        let supported = cameraState?.hasFlash == true && cameraState?.isFront == false
        flashButton.isEnabled = supported && !isCapturing && !isSwitching && !isStarting
        flashButton.alpha = supported ? 1 : 0.35
        if !supported {
            flashMode = .off
        }

        let symbol: String
        switch flashMode {
        case .on: symbol = "bolt.fill"
        case .auto: symbol = "bolt.badge.automatic.fill"
        default: symbol = "bolt.slash.fill"
        }
        flashButton.configuration?.image = UIImage(systemName: symbol)
        flashButton.configuration?.baseForegroundColor = flashMode == .off ? .white : .systemYellow
    }

    func showCapturedImage(_ image: UIImage) {
        capturedImage = image
        capturedImageView.image = image
        capturedImageView.isHidden = false
        cameraControls.isHidden = true
        rearLensContainer.isHidden = true
        resultControls.isHidden = false
        depthPanel.isHidden = true
        resultInfoLabel.isHidden = false
        retryButton.isHidden = true
        focusIndicator.alpha = 0
        if let photo = processedPhoto {
            updateResultDescription()
            compareButton.isHidden = !photo.outcome.canCompare
            legacyCompareButton.isHidden = legacyComparisonImage == nil
            comparisonControls.isHidden = false
            resultInfoLabel.textColor = photo.outcome.isDepthApplied ? .white : .systemYellow
        }
        camera.stop()
    }

    func updateResultDescription() {
        guard let photo = processedPhoto else { return }
        let aperture = photo.outcome.canCompare ? String(format: " · f/%.1f", photo.aperture) : ""
        let title = photo.outcome.canCompare ? "\(photo.rendererTitle) · \(photo.outcome.message)" : photo.outcome.message
        resultInfoLabel.text = "  \(title)\(aperture)  \n  \(photo.pixelWidth) × \(photo.pixelHeight) · JPEG  "
    }

    func flashScreen() {
        dimView.alpha = 0.85
        UIView.animate(withDuration: 0.25) {
            self.dimView.alpha = 0
        }
    }

    func showFocusIndicator(at point: CGPoint) {
        focusIndicator.center = point
        focusIndicator.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        focusIndicator.alpha = 1
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            self.focusIndicator.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 0.45) {
                self.focusIndicator.alpha = 0
            }
        }
    }

    func updatePreviewOrientation() {
        guard let connection = previewLayer.connection else { return }
        let angle = previewRotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = cameraState?.isFront == true
        }
    }

    var previewRotationAngle: CGFloat {
        // 保留 iOS 17 可用的场景方向接口；不依赖新系统的 Geometry 属性。
        // 新 SDK 的弃用提示不影响 iOS 17 的调用及兼容性。
        switch view.window?.windowScene?.interfaceOrientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        default: return 90
        }
    }

    func saveToPhotoLibrary(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        TestLog.shared.record("photo library add permission=\(status.rawValue)", category: "save", captureID: processedPhoto?.captureID)
        guard status == .authorized || status == .limited else {
            throw CameraError.photoLibraryDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = "public.jpeg"
            options.originalFilename = "TestCamer-\(UUID().uuidString).jpg"
            request.addResource(with: .photo, data: data, options: options)
        }
    }

    func presentError(_ error: Error) {
        TestLog.shared.record("operation failed: \(TestLog.errorDescription(error))", category: "ui")
        presentAlert(title: "无法完成操作", message: error.localizedDescription)
    }

    func presentAlert(title: String, message: String) {
        guard isScreenVisible, UIApplication.shared.applicationState != .background,
              presentedViewController == nil else {
            TestLog.shared.record("alert not shown: \(title): \(message)", category: "ui")
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}


// MARK: - 拍后景深控件（原 Demo 的相机与结果控件保留）

private extension ViewController {
    func setupDepthControls() {
        depthPanel.translatesAutoresizingMaskIntoConstraints = false
        depthPanel.layer.cornerRadius = 16
        depthPanel.clipsToBounds = true
        view.addSubview(depthPanel)

        depthTitleLabel.text = "智能景深"
        depthTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        depthTitleLabel.textColor = .white
        depthHintLabel.font = .systemFont(ofSize: 12)
        depthHintLabel.textColor = .lightGray
        depthHintLabel.numberOfLines = 2
        depthSwitch.isOn = true
        depthSwitch.accessibilityLabel = "拍后景深开关"
        depthSwitch.addTarget(self, action: #selector(depthSwitchChanged), for: .valueChanged)

        apertureSlider.minimumValue = 0
        apertureSlider.maximumValue = Float(DepthCapturePolicy.apertures.count - 1)
        apertureSlider.value = 0 // 从参考照片使用的 f/1.4 开始。
        apertureSlider.minimumTrackTintColor = .systemYellow
        apertureSlider.accessibilityLabel = "虚拟光圈，仅成片生效"
        apertureSlider.addTarget(self, action: #selector(apertureChanged), for: .valueChanged)
        apertureLabel.textColor = .systemYellow
        apertureLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        apertureLabel.textAlignment = .right

        let heading = UIStackView(arrangedSubviews: [depthTitleLabel, depthSwitch])
        heading.axis = .horizontal
        heading.alignment = .center
        let apertureRow = UIStackView(arrangedSubviews: [apertureSlider, apertureLabel])
        apertureRow.axis = .horizontal
        apertureRow.alignment = .center
        apertureRow.spacing = 12
        let stack = UIStackView(arrangedSubviews: [heading, apertureRow, depthHintLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        depthPanel.contentView.addSubview(stack)

        resultInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        resultInfoLabel.numberOfLines = 0
        resultInfoLabel.textColor = .white
        resultInfoLabel.textAlignment = .center
        resultInfoLabel.font = .systemFont(ofSize: 13, weight: .medium)
        resultInfoLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        resultInfoLabel.layer.cornerRadius = 12
        resultInfoLabel.clipsToBounds = true
        resultInfoLabel.isHidden = true
        view.addSubview(resultInfoLabel)

        configureTextButton(compareButton, title: "按住看原图", action: #selector(endComparison))
        compareButton.addTarget(self, action: #selector(beginComparison), for: [.touchDown, .touchDragEnter])
        compareButton.addTarget(self, action: #selector(endComparison),
                                for: [.touchUpOutside, .touchCancel, .touchDragExit])
        compareButton.isHidden = true
        configureTextButton(legacyCompareButton, title: "按住看旧版", action: #selector(endComparison))
        legacyCompareButton.addTarget(self, action: #selector(beginLegacyComparison), for: [.touchDown, .touchDragEnter])
        legacyCompareButton.addTarget(self, action: #selector(endComparison),
                                      for: [.touchUpOutside, .touchCancel, .touchDragExit])
        legacyCompareButton.isHidden = true
        configureTextButton(diagnosticsButton, title: "景深诊断", action: #selector(showDepthDiagnostics))
        for button in [compareButton, legacyCompareButton, diagnosticsButton] {
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 6)
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var attributes = $0
                attributes[AttributeScopes.UIKitAttributes.FontAttribute.self] = UIFont.systemFont(ofSize: 13, weight: .medium)
                return attributes
            }
        }
        comparisonControls.axis = .horizontal
        comparisonControls.distribution = .fillEqually
        comparisonControls.spacing = 12
        comparisonControls.translatesAutoresizingMaskIntoConstraints = false
        comparisonControls.addArrangedSubview(compareButton)
        comparisonControls.addArrangedSubview(legacyCompareButton)
        comparisonControls.addArrangedSubview(diagnosticsButton)
        comparisonControls.isHidden = true
        view.addSubview(comparisonControls)
        configureTextButton(retryButton, title: "重新开启相机", action: #selector(retryCameraTapped))
        retryButton.isHidden = true
        view.addSubview(retryButton)
        processingSpinner.translatesAutoresizingMaskIntoConstraints = false
        processingSpinner.color = .white
        processingSpinner.hidesWhenStopped = true
        view.addSubview(processingSpinner)

        NSLayoutConstraint.activate([
            libraryButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            libraryButton.centerYAnchor.constraint(equalTo: exportLogButton.centerYAnchor),
            libraryButton.trailingAnchor.constraint(lessThanOrEqualTo: exportLogButton.leadingAnchor, constant: -8),
            libraryButton.heightAnchor.constraint(equalToConstant: 36),
            exportLogButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            exportLogButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            exportLogButton.heightAnchor.constraint(equalToConstant: 36),
            depthPanel.topAnchor.constraint(equalTo: exportLogButton.bottomAnchor, constant: 12),
            depthPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            depthPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: depthPanel.contentView.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: depthPanel.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: depthPanel.contentView.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: depthPanel.contentView.bottomAnchor, constant: -10),
            apertureLabel.widthAnchor.constraint(equalToConstant: 62),
            resultInfoLabel.topAnchor.constraint(equalTo: exportLogButton.bottomAnchor, constant: 12),
            resultInfoLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            resultInfoLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            resultInfoLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            comparisonControls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            comparisonControls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            comparisonControls.bottomAnchor.constraint(equalTo: resultControls.topAnchor, constant: -16),
            comparisonControls.heightAnchor.constraint(equalToConstant: 44),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            processingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            processingSpinner.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -16)
        ])
        updateDepthPanel()
    }

    func updateDepthPanel() {
        let supported = cameraState?.depthSupported == true
        let active = wantsDepth
        depthSwitch.setOn(active, animated: false)
        depthTitleLabel.text = active ? "智能景深" : "普通拍照"
        if let state = cameraState {
            let isMain = !state.isFront && state.rearLensOptions.first {
                $0.id == state.selectedRearLensID
            }?.kind == .wide
            if active && isMain && supported { depthTitleLabel.text = "苹果景深" }
            let zoom = String(format: "%.1f×", Double(state.zoomFactor))
                .replacingOccurrences(of: ".0×", with: "×")
            let fieldOfView = abs(state.zoomFactor - 1) < 0.001 ? "原生视角" : "数码变焦 \(zoom)"
            let lensHint = "\(state.activeLensName) · \(fieldOfView)"
            let sourceHint = supported
                ? (isMain ? "主摄成像 · 苹果原生景深优先" : "原生深度 · 智能渲染")
                : (isMain ? "主摄原生深度不可用 · 本机估计" : "本机估计深度")
            let captureHint = active ? "\(sourceHint) · 拍完可换焦、调虚化" : "景深已关闭"
            depthHintLabel.text = "\(lensHint)\n\(captureHint)"
        } else {
            depthHintLabel.text = "正在检测当前镜头的景深能力…"
        }
        let aperture = DepthCapturePolicy.aperture(sliderValue: apertureSlider.value)
        apertureLabel.text = String(format: "f/%.1f", aperture)
        apertureSlider.accessibilityValue = apertureLabel.text
        apertureSlider.alpha = active ? 1 : 0.35
        let available = cameraState?.isRunning == true && capturedImage == nil && !isCapturing
            && !isSwitching && !isStarting && !isExportingLog
        depthSwitch.isEnabled = available
        apertureSlider.isEnabled = active && available
    }

    func updateControlAvailability() {
        let ready = isScreenVisible && cameraState?.isRunning == true && capturedImage == nil
            && !isStarting && !isCapturing && !isSwitching && !isExportingLog
        exportLogButton.isEnabled = !isCapturing && !isStarting && !isSwitching && !isExportingLog
        libraryButton.isEnabled = !isCapturing && !isSaving && !isStarting && !isSwitching && !isExportingLog
        shutterButton.isEnabled = ready
        shutterButton.alpha = ready ? 1 : 0.5
        switchButton.isEnabled = ready
        updateFlashButton()
        flashButton.isEnabled = ready && cameraState?.hasFlash == true && cameraState?.isFront == false
        retakeButton.isEnabled = !isSaving && !isCapturing
        saveButton.isEnabled = processedPhoto != nil && !isSaving && !isCapturing
        compareButton.isEnabled = !isSaving
        legacyCompareButton.isEnabled = !isSaving
        diagnosticsButton.isEnabled = processedPhoto != nil && !isSaving
        updateDepthPanel()
        updateRearLensControls(ready: ready)
    }
}
