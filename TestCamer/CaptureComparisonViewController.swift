import UIKit

/// Inspection of the original capture is separate from the current edit/export.
@MainActor
final class CaptureComparisonViewController: UIViewController {
    private let photo: ProcessedPhoto
    private let imageView = UIImageView()
    private let selector: UISegmentedControl
    private let note = UILabel()

    init(photo: ProcessedPhoto) {
        self.photo = photo
        selector = UISegmentedControl(items: photo.legacyComparison != nil
            ? ["原图", "初始效果", "旧版"] : ["原图", "初始效果"])
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "拍摄时的同帧对照"
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done,
            target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "诊断", style: .plain,
            target: self, action: #selector(diagnostics))
        imageView.contentMode = .scaleAspectFit
        selector.selectedSegmentIndex = 1
        selector.addTarget(self, action: #selector(selectionChanged), for: .valueChanged)
        note.textColor = .lightGray
        note.font = .systemFont(ofSize: 13)
        note.textAlignment = .center
        note.numberOfLines = 0
        for item in [imageView, selector, note] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            selector.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            selector.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            imageView.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -12),
            note.leadingAnchor.constraint(equalTo: selector.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: selector.trailingAnchor),
            note.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        selectionChanged()
    }

    @objc private func selectionChanged() {
        let data: Data
        let result: String
        switch selector.selectedSegmentIndex {
        case 0: data = photo.originalPreviewData; result = "未添加景深的原图"
        case 2:
            data = photo.legacyComparison?.previewData ?? photo.previewData
            result = "旧版 · \(photo.legacyComparison?.outcome.message ?? "无结果")"
        default: data = photo.previewData; result = "\(photo.rendererTitle) · \(photo.outcome.message)"
        }
        imageView.image = UIImage(data: data)
        note.text = String(format: "%@ · 拍摄光圈 f/%.1f\n此处只查看初始对照，不改变当前编辑或导出。", result, photo.aperture)
        if photo.appleFallbackReason != nil {
            note.text? += photo.outcome.canCompare
                ? "\n本次苹果景深不可用，已自动回退智能景深。"
                : "\n本次景深处理未成功，已保留原图。"
        }
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func diagnostics() {
        let screen = DepthDiagnosticsViewController(text: "以下为拍摄时的初始效果诊断，不代表后续换焦结果。\n\n" + photo.diagnosticText,
            maskData: photo.diagnosticMaskData, isOutputDifference: photo.diagnosticImageIsDifference)
        present(UINavigationController(rootViewController: screen), animated: true)
    }
}
