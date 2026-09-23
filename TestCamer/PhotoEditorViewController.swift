import UIKit
import Photos
import ImageIO

/// Edits always consume document.sourceData. The preview is never a render input.
@MainActor
final class PhotoEditorViewController: UIViewController {
    private var document: EditablePhotoDocument
    private let store: EditablePhotoStore
    private let renderer = PhotoEditingRenderer()
    private var session: PhotoEditingSession
    private var renderTask: Task<Void, Never>?
    private var originalImage: UIImage?
    private var renderedImage: UIImage?
    private var isComparing = false
    private var isExporting = false
    private var isPersisting = false
    private var saveError: String?
    private var renderError: String?
    private var isClosed = false
    private let exif: UInt32
    private let captureDiagnostics: ProcessedPhoto?
    var onClose: (() -> Void)?

    private let imageView = UIImageView()
    private let focusBox = UIView()
    private let slider = UISlider()
    private let apertureLabel = UILabel()
    private let rendererLabel = UILabel()
    private let stateLabel = UILabel()
    private let compareButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let retrySaveButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(document: EditablePhotoDocument, store: EditablePhotoStore,
         originalPreviewData: Data? = nil, initialSaveError: String? = nil,
         captureDiagnostics: ProcessedPhoto? = nil) {
        self.captureDiagnostics = captureDiagnostics
        self.document = document
        self.store = store
        self.session = PhotoEditingSession(recipe: document.recipe)
        self.renderedImage = UIImage(data: document.previewData)
        self.originalImage = originalPreviewData.flatMap(UIImage.init(data:))
        self.saveError = initialSaveError
        if let source = CGImageSourceCreateWithData(document.sourceData as CFData, nil),
           let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            let value = (info[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
            exif = (1...8).contains(value) ? value : 1
        } else { exif = 1 }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "景深编辑"
        view.backgroundColor = .black
        isModalInPresentation = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done,
                                                           target: self, action: #selector(closeTapped))
        if captureDiagnostics != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "拍摄对照", style: .plain,
                target: self, action: #selector(showCaptureDiagnostics))
        }
        setupUI()
        syncControls()
        imageView.image = renderedImage
        refreshState()
        if originalImage == nil {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await renderer.originalPreview(sourceData: document.sourceData, maximumDimension: 1600)
                    guard !isClosed else { return }
                    originalImage = UIImage(data: data)
                    refreshState()
                } catch {
                    TestLog.shared.record("editor original preview failed: \(error.localizedDescription)", category: "edit")
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionFocusBox()
    }

    private func setupUI() {
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.clipsToBounds = true
        imageView.accessibilityIdentifier = "editablePhoto"
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:))))
        focusBox.layer.borderWidth = 1.5
        focusBox.layer.borderColor = UIColor.systemYellow.cgColor
        focusBox.isUserInteractionEnabled = false
        focusBox.bounds.size = CGSize(width: 54, height: 54)
        imageView.addSubview(focusBox)
        slider.minimumValue = 0
        slider.maximumValue = Float(DepthCapturePolicy.apertures.count - 1)
        slider.minimumTrackTintColor = .systemYellow
        slider.accessibilityLabel = "景深光圈"
        slider.accessibilityIdentifier = "editAperture"
        slider.addTarget(self, action: #selector(apertureChanged), for: .valueChanged)
        apertureLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        apertureLabel.textColor = .systemYellow
        apertureLabel.setContentHuggingPriority(.required, for: .horizontal)
        rendererLabel.font = .systemFont(ofSize: 13, weight: .medium)
        rendererLabel.textColor = .lightGray
        rendererLabel.textAlignment = .center
        rendererLabel.numberOfLines = 0
        rendererLabel.accessibilityIdentifier = "editRenderer"
        updateRendererLabel()
        stateLabel.font = .systemFont(ofSize: 13)
        stateLabel.textColor = .lightGray
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateLabel.accessibilityIdentifier = "editStatus"
        configure(compareButton, title: "按住看原图", action: #selector(endComparison))
        compareButton.addTarget(self, action: #selector(beginComparison), for: [.touchDown, .touchDragEnter])
        compareButton.addTarget(self, action: #selector(endComparison), for: [.touchCancel, .touchDragExit, .touchUpOutside])
        configure(resetButton, title: "恢复初始", action: #selector(resetTapped))
        configure(exportButton, title: "保存到相册", action: #selector(exportTapped))
        exportButton.configuration?.baseBackgroundColor = .white
        exportButton.configuration?.baseForegroundColor = .black
        exportButton.accessibilityIdentifier = "exportEditedPhoto"
        configure(retrySaveButton, title: "重试本机保存", action: #selector(retrySaveTapped))
        let apertureRow = UIStackView(arrangedSubviews: [slider, apertureLabel])
        apertureRow.axis = .horizontal
        apertureRow.spacing = 14
        let actionRow = UIStackView(arrangedSubviews: [compareButton, resetButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 10
        actionRow.distribution = .fillEqually
        let panel = UIStackView(arrangedSubviews: [apertureRow, rendererLabel, stateLabel, retrySaveButton, actionRow, exportButton])
        panel.axis = .vertical
        panel.spacing = 12
        for item in [imageView, panel, spinner] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        spinner.color = .white
        spinner.hidesWhenStopped = true
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            imageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -12),
            panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            actionRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            exportButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            spinner.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: imageView.centerYAnchor)
        ])
    }

    private func configure(_ button: UIButton, title: String, action: Selector) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = .darkGray
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func imageTapped(_ gesture: UITapGestureRecognizer) {
        guard !isExporting, !isComparing, let image = renderedImage,
              let focus = PhotoEditGeometry.sensorPoint(at: gesture.location(in: imageView),
                    viewSize: imageView.bounds.size, imageSize: image.size, exif: exif) else { return }
        requestPreview(PhotoEditRecipe(aperture: session.desiredRecipe.aperture, sensorFocus: focus))
    }

    @objc private func apertureChanged() {
        guard !isExporting else { return }
        slider.value = slider.value.rounded()
        requestPreview(PhotoEditRecipe(aperture: DepthCapturePolicy.aperture(sliderValue: slider.value),
                                       sensorFocus: session.desiredRecipe.sensorFocus))
    }

    @objc private func resetTapped() {
        guard !isExporting else { return }
        requestPreview(document.initialRecipe)
    }

    private func requestPreview(_ recipe: PhotoEditRecipe) {
        endComparison()
        session.select(recipe)
        renderError = nil
        syncControls()
        refreshState()
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            guard let self else { return }
            while !isClosed, let request = session.beginNext() {
                refreshState()
                do {
                    let result = try await renderer.render(sourceData: document.sourceData,
                        recipe: request.recipe, maximumDimension: 1600, depthData: document.depthData)
                    guard let image = UIImage(data: result.jpegData) else { throw CameraError.captureFailed }
                    if session.complete(request, succeeded: true) {
                        document.renderingInfo = PhotoRenderingInfo(
                            appleFallbackReason: document.renderingInfo?.appleFallbackReason,
                            usedAppleMetadataCompatibility: result.usedMetadataCompatibility)
                        updateRendererLabel()
                        renderedImage = image
                        imageView.image = image
                        document.recipe = request.recipe
                        document.previewData = result.jpegData
                        document.updatedAt = Date()
                        syncControls()
                        await persistCurrent()
                    }
                } catch {
                    if session.complete(request, succeeded: false) {
                        renderError = "本次调整失败，已保留上一效果：\(error.localizedDescription)"
                        syncControls()
                    }
                }
            }
            renderTask = nil
            refreshState()
        }
    }

    private func persistCurrent() async {
        isPersisting = true
        refreshState()
        do {
            try await store.save(document)
            saveError = nil
        } catch { saveError = error.localizedDescription }
        isPersisting = false
        refreshState()
    }

    @objc private func retrySaveTapped() {
        guard renderTask == nil, !isPersisting, !isExporting else { return }
        Task { await persistCurrent() }
    }

    private func syncControls() {
        let value = session.desiredRecipe.aperture
        let index = DepthCapturePolicy.apertures.enumerated().min {
            abs($0.element-value) < abs($1.element-value)
        }?.offset ?? 0
        slider.value = Float(index)
        apertureLabel.text = String(format: "f/%.1f", value)
        slider.accessibilityValue = apertureLabel.text
        positionFocusBox()
    }

    private func updateRendererLabel() {
        // 附件决定实际编辑路线；重开照片也沿用同一规则，不能只按拍摄镜头推断。
        if document.depthData != nil {
            rendererLabel.text = document.renderingInfo?.appleFallbackReason != nil
                ? "智能景深 · 本次苹果景深不可用，已自动回退"
                : "智能景深 · 本机计算"
        } else {
            rendererLabel.text = document.renderingInfo?.usedAppleMetadataCompatibility == true
                ? "苹果景深（兼容）" : "苹果景深"
        }
    }

    private func positionFocusBox() {
        guard !isComparing, let image = renderedImage,
              let focus = session.desiredRecipe.sensorFocus,
              let point = PhotoEditGeometry.displayPoint(sensorPoint: focus, viewSize: imageView.bounds.size,
                                                          imageSize: image.size, exif: exif) else {
            focusBox.isHidden = true
            return
        }
        focusBox.isHidden = false
        focusBox.center = point
    }

    private func refreshState() {
        let rendering = !session.isSettled || renderTask != nil
        let busy = rendering || isExporting || isPersisting
        navigationItem.leftBarButtonItem?.isEnabled = !busy
        navigationItem.rightBarButtonItem?.isEnabled = !busy
        slider.isEnabled = !isExporting
        resetButton.isEnabled = !isExporting
        compareButton.isEnabled = originalImage != nil && !busy
        exportButton.isEnabled = !busy && renderedImage != nil
        retrySaveButton.isHidden = saveError == nil
        retrySaveButton.isEnabled = !busy
        imageView.isUserInteractionEnabled = !isExporting
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        if isExporting { stateLabel.text = "正在生成完整尺寸成片并保存…" }
        else if !session.isSettled { stateLabel.text = "正在调整景深…" }
        else if isPersisting { stateLabel.text = "正在保存到本机…" }
        else if let error = saveError { stateLabel.text = "本机保存失败：\(error)" }
        else if let error = renderError { stateLabel.text = error }
        else if isComparing { stateLabel.text = "原图 · 松开恢复当前效果" }
        else { stateLabel.text = "点击照片切换焦点 · 已保存到本机" }
        stateLabel.textColor = saveError != nil || renderError != nil ? .systemYellow : .lightGray
    }

    @objc private func beginComparison() {
        guard let originalImage, session.isSettled, renderTask == nil, !isExporting else { return }
        isComparing = true
        imageView.image = originalImage
        focusBox.isHidden = true
        refreshState()
    }

    @objc private func endComparison() {
        isComparing = false
        imageView.image = renderedImage
        positionFocusBox()
        refreshState()
    }

    @objc private func exportTapped() {
        guard session.isSettled, renderTask == nil, !isPersisting, !isExporting else { return }
        endComparison()
        let recipe = session.displayedRecipe
        isExporting = true
        refreshState()
        Task {
            defer { isExporting = false; refreshState() }
            do {
                let result = try await renderer.render(sourceData: document.sourceData, recipe: recipe,
                                                       depthData: document.depthData)
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else { throw CameraError.photoLibraryDenied }
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = "public.jpeg"
                    options.originalFilename = "TestCamer-\(UUID().uuidString).jpg"
                    request.addResource(with: .photo, data: result.jpegData, options: options)
                }
                showMessage(title: "已保存到相册", message: "已保存当前焦点和光圈的完整尺寸成片。继续编辑请从 App 的“可编辑照片”进入。")
            } catch { showMessage(title: "保存失败", message: error.localizedDescription) }
        }
    }

    @objc private func showCaptureDiagnostics() {
        guard let photo = captureDiagnostics, presentedViewController == nil else { return }
        let screen = CaptureComparisonViewController(photo: photo)
        let navigation = UINavigationController(rootViewController: screen)
        present(navigation, animated: true)
    }

    @objc private func closeTapped() {
        guard session.isSettled, renderTask == nil, !isPersisting, !isExporting else { return }
        if saveError != nil {
            let alert = UIAlertController(title: "修改尚未保存到本机", message: "可以重试保存，或放弃本次未保存的修改。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "重试保存", style: .default) { [weak self] _ in self?.retrySaveTapped() })
            alert.addAction(UIAlertAction(title: "放弃未保存修改", style: .destructive) { [weak self] _ in self?.finishClosing() })
            alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel))
            present(alert, animated: true)
        } else { finishClosing() }
    }

    private func finishClosing() {
        isClosed = true
        session.invalidate()
        renderTask?.cancel()
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
            onClose?()
        } else {
            dismiss(animated: true) { [onClose] in onClose?() }
        }
    }

    private func showMessage(title: String, message: String) {
        guard presentedViewController == nil, !isClosed else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
