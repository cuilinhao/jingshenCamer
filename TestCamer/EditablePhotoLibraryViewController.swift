import UIKit
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

/// 本机保留的原图和编辑参数；系统相册里的导出成片独立管理。
@MainActor
final class EditablePhotoLibraryViewController: UITableViewController {
    private let store: EditablePhotoStore
    private var photos: [EditablePhotoSummary] = []
    private var operationTask: Task<Void, Never>?
    private var isBusy = false
    private var isClosed = false
    private let importer = PhotoLibraryImporter()
    private var isPickingPhoto = false
    private var importID: UUID?
    private var importProgress: Progress?
    private let emptyMessage = "还没有可编辑照片\n可从右上角“系统相册”选择照片，或拍摄景深照片后继续编辑。"
    private let thumbnailCache = NSCache<NSURL, UIImage>()
    private let statusLabel = UILabel()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(store: EditablePhotoStore) {
        self.store = store
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "可编辑照片"
        view.backgroundColor = .black
        // 使用明确的“完成”入口，避免磁盘操作结束后向已关闭页面推入编辑器。
        isModalInPresentation = true
        navigationController?.isModalInPresentation = true
        setBusy(false)
        tableView.register(EditablePhotoCell.self, forCellReuseIdentifier: EditablePhotoCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 106
        tableView.backgroundColor = .black
        tableView.accessibilityIdentifier = "editablePhotoLibrary"
        thumbnailCache.countLimit = 60

        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusSpinner.hidesWhenStopped = true
        retryButton.setTitle("重新加载", for: .normal)
        retryButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [statusSpinner, statusLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let background = UIView()
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28)
        ])
        tableView.backgroundView = background
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 编辑器在完成持久化后才返回，所以此时读取的参数和缩略图属于同一版本。
        reloadPhotos()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            isClosed = true
            operationTask?.cancel()
            importProgress?.cancel()
        }
    }

    @objc private func reloadTapped() { reloadPhotos() }

    private func reloadPhotos() {
        guard !isBusy, !isClosed, !isPickingPhoto else { return }
        setBusy(true, message: "正在读取本机照片…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await store.list()
                guard !isClosed, !Task.isCancelled else { return }
                photos = entries
                setBusy(false)
                tableView.reloadData()
                restoreListBackground()
            } catch {
                guard !isClosed, !Task.isCancelled else { return }
                setBusy(false)
                if photos.isEmpty {
                    setBackground(message: "无法读取本机照片：\n\(error.localizedDescription)", canRetry: true)
                } else {
                    setBackground(message: nil)
                    showError(title: "刷新失败", message: error.localizedDescription)
                }
            }
            operationTask = nil
        }
    }

    @objc private func importTapped() {
        guard !isBusy, !isClosed, !isPickingPhoto, presentedViewController == nil else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        // 尽可能保留 HEIC 容器及深度附件，避免先转成 UIImage/JPEG 丢失数据。
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        isPickingPhoto = true
        present(picker, animated: true)
        picker.presentationController?.delegate = self
    }

    private func importPhoto(from provider: NSItemProvider) {
        guard !isBusy, !isClosed else { return }
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            showError(title: "无法导入照片", message: "请选择支持的图片文件。")
            return
        }
        let id = UUID()
        importID = id
        setBusy(true, message: "正在读取相册照片…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await loadPhotoData(from: provider)
                try Task.checkCancellation()
                guard !isClosed, importID == id else { return }
                importProgress = nil
                setBusy(true, message: "正在准备景深编辑…")
                let imported = try await importer.prepare(data: data)
                try Task.checkCancellation()
                guard !isClosed, importID == id else { return }
                // 写入开始后暂时禁止取消，避免已保存的照片被误认为取消导入。
                importID = nil
                setBusy(true, message: "正在保存本机照片…")
                var saveError: String?
                do { try await store.save(imported.document) }
                catch { saveError = error.localizedDescription }
                guard !isClosed, !Task.isCancelled else { return }
                setBusy(false)
                restoreListBackground()
                operationTask = nil
                let editor = PhotoEditorViewController(document: imported.document, store: store,
                    originalPreviewData: imported.originalPreviewData, initialSaveError: saveError)
                navigationController?.pushViewController(editor, animated: true)
            } catch {
                guard !isClosed, importID == id else { return }
                finishImport()
                if !(error is CancellationError) {
                    showError(title: "无法导入照片", message: error.localizedDescription)
                }
            }
        }
    }

    private func loadPhotoData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            importProgress = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    // 系统临时 URL 只在回调内有效；在回调结束前读完，后台不重编码。
                    continuation.resume(with: Result { try Data(contentsOf: url) })
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    @objc private func cancelImportTapped() {
        guard importID != nil else { return }
        operationTask?.cancel()
        importProgress?.cancel()
        finishImport()
    }

    private func finishImport() {
        importID = nil
        importProgress = nil
        operationTask = nil
        setBusy(false)
        restoreListBackground()
    }

    private func restoreListBackground() {
        setBackground(message: photos.isEmpty ? emptyMessage : nil)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { photos.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: EditablePhotoCell.reuseIdentifier, for: indexPath) as! EditablePhotoCell
        let photo = photos[indexPath.row]
        cell.configure(id: photo.id, title: dateFormatter.string(from: photo.createdAt),
                       subtitle: photo.loadErrorDescription.map { "数据异常：\($0) · 可左滑删除" }
                           ?? "上次编辑：\(dateFormatter.string(from: photo.updatedAt))",
                       isDamaged: photo.loadErrorDescription != nil)
        guard photo.loadErrorDescription == nil else { return cell }
        if let cached = thumbnailCache.object(forKey: photo.previewURL as NSURL) {
            cell.thumbnailView.image = cached
        } else {
            let url = photo.previewURL
            cell.thumbnailTask = Task { [weak self, weak cell] in
                let result = await Task.detached(priority: .utility) { Self.loadThumbnail(at: url) }.value
                guard !Task.isCancelled, let self, let cell, cell.representedID == photo.id else { return }
                if let image = result.image {
                    let thumbnail = UIImage(cgImage: image)
                    thumbnailCache.setObject(thumbnail, forKey: url as NSURL)
                    cell.thumbnailView.image = thumbnail
                } else {
                    cell.detailLabel.text = "预览无法读取，可点击尝试打开照片。"
                    cell.detailLabel.textColor = .systemYellow
                }
                cell.thumbnailTask = nil
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isBusy, !isClosed, photos.indices.contains(indexPath.row) else { return }
        let photo = photos[indexPath.row]
        setBusy(true, message: "正在打开照片…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await store.load(id: photo.id)
                guard !isClosed, !Task.isCancelled else { return }
                setBusy(false)
                setBackground(message: nil)
                let editor = PhotoEditorViewController(document: document, store: store)
                navigationController?.pushViewController(editor, animated: true)
            } catch {
                guard !isClosed, !Task.isCancelled else { return }
                setBusy(false)
                setBackground(message: nil)
                showError(title: "无法打开照片", message: error.localizedDescription + "\n可左滑删除这张本机照片。")
            }
            operationTask = nil
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { !isBusy }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isBusy, photos.indices.contains(indexPath.row) else { return nil }
        let id = photos[indexPath.row].id
        let action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            completion(false)
            guard let self, !isBusy, !isClosed, presentedViewController == nil else { return }
            let alert = UIAlertController(title: "删除本机可编辑照片？",
                                          message: "这会删除 App 内的原始照片、深度数据和编辑记录，无法恢复。系统相册中已经导出的照片不受影响。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in self?.deletePhoto(id: id) })
            present(alert, animated: true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private func deletePhoto(id: UUID) {
        guard !isBusy, !isClosed else { return }
        setBusy(true, message: "正在删除本机照片…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.delete(id: id)
                guard !isClosed, !Task.isCancelled else { return }
                if let item = photos.first(where: { $0.id == id }) {
                    thumbnailCache.removeObject(forKey: item.previewURL as NSURL)
                }
                photos.removeAll { $0.id == id }
                setBusy(false)
                tableView.reloadData()
                restoreListBackground()
            } catch {
                guard !isClosed, !Task.isCancelled else { return }
                setBusy(false)
                setBackground(message: nil)
                showError(title: "删除失败", message: error.localizedDescription)
            }
            operationTask = nil
        }
    }

    private func setBusy(_ busy: Bool, message: String? = nil) {
        isBusy = busy
        navigationItem.prompt = busy ? message : nil
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: importID == nil ? "完成" : "取消导入", style: .done, target: self,
            action: importID == nil ? #selector(closeTapped) : #selector(cancelImportTapped))
        navigationItem.leftBarButtonItem?.isEnabled = !busy || importID != nil
        tableView.isUserInteractionEnabled = !busy
        if busy {
            if photos.isEmpty { setBackground(message: message) }
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: spinner)]
            statusSpinner.startAnimating()
        } else {
            statusSpinner.stopAnimating()
            let importButton = UIBarButtonItem(title: "系统相册", style: .plain,
                                               target: self, action: #selector(importTapped))
            importButton.accessibilityIdentifier = "importPhotoFromLibrary"
            let refreshButton = UIBarButtonItem(barButtonSystemItem: .refresh,
                                                target: self, action: #selector(reloadTapped))
            refreshButton.accessibilityLabel = "刷新本机照片"
            navigationItem.rightBarButtonItems = [importButton, refreshButton]
        }
    }

    private func setBackground(message: String?, canRetry: Bool = false) {
        tableView.backgroundView?.isHidden = message == nil
        statusLabel.text = message
        retryButton.isHidden = !canRetry
    }

    @objc private func closeTapped() {
        guard !isBusy, !isClosed else { return }
        isClosed = true
        operationTask?.cancel()
        dismiss(animated: true)
    }

    private func showError(title: String, message: String) {
        guard !isClosed, presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // CGImage 是不可变图像；跨任务交付后仅在主线程创建和更新 UIKit 对象。
    private struct Thumbnail: @unchecked Sendable { let image: CGImage? }

    nonisolated private static func loadThumbnail(at url: URL) -> Thumbnail {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return Thumbnail(image: nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 200,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return Thumbnail(image: CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
    }
}

extension EditablePhotoLibraryViewController: PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController is PHPickerViewController {
            isPickingPhoto = false
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard isPickingPhoto else { return }
        // 等系统选择器完成关闭再推入编辑器，取消选择不改变本机列表。
        picker.dismiss(animated: true) { [weak self] in
            guard let self, !isClosed else { return }
            isPickingPhoto = false
            if let selection = results.first {
                importPhoto(from: selection.itemProvider)
            }
        }
    }
}

@MainActor
private final class EditablePhotoCell: UITableViewCell {
    static let reuseIdentifier = "EditablePhotoCell"
    var representedID: UUID?
    var thumbnailTask: Task<Void, Never>?
    let thumbnailView = UIImageView()
    let titleLabel = UILabel()
    let detailLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .black
        accessoryType = .disclosureIndicator
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 8
        thumbnailView.backgroundColor = .secondarySystemBackground
        thumbnailView.tintColor = .secondaryLabel
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.numberOfLines = 3
        detailLabel.adjustsFontForContentSizeCategory = true
        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 6
        for item in [thumbnailView, labels] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            thumbnailView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 76),
            thumbnailView.heightAnchor.constraint(equalToConstant: 80),
            thumbnailView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            thumbnailView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            labels.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 14),
            labels.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            labels.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            labels.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        representedID = nil
        thumbnailView.image = nil
    }

    func configure(id: UUID, title: String, subtitle: String, isDamaged: Bool) {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        representedID = id
        titleLabel.text = title
        detailLabel.text = subtitle
        detailLabel.textColor = isDamaged ? .systemYellow : .secondaryLabel
        thumbnailView.image = UIImage(systemName: isDamaged ? "exclamationmark.triangle" : "photo")
        accessibilityIdentifier = "editablePhoto-\(id.uuidString)"
    }
}
