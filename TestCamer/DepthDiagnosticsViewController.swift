// 结果页诊断：诊断文字会进入 TestLog；不保存原图/深度/点位。
import UIKit

@MainActor
final class DepthDiagnosticsViewController: UIViewController {
    private let text: String
    private let maskData: Data?
    private let isOutputDifference: Bool

    init(text: String, maskData: Data?, isOutputDifference: Bool = false) {
        self.text = text; self.maskData = maskData
        self.isOutputDifference = isOutputDifference
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "景深诊断 · v3"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done,
                                                           target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "复制信息", style: .plain,
                                                            target: self, action: #selector(copyInfo))
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        let explanation = UILabel()
        explanation.font = .preferredFont(forTextStyle: .body)
        explanation.numberOfLines = 0
        let imageExplanation = isOutputDifference
            ? "下方是成片与原图的像素差异图（放大 4 倍）。越亮表示变化越大；黑色表示变化较小。它不是苹果滤镜的内部虚化遮罩，也不能单独证明画质合格。"
            : "下方是旧版处理实际使用的虚化分布。白色越亮，虚化半径越大；黑色表示保留清晰或深度无效。"
        explanation.text = imageExplanation + "\n\n诊断文字会写入 TestLog，可从拍摄页右上角导出；不写入照片，也不记录聚焦坐标。"
        stack.addArrangedSubview(explanation)
        if let maskData, let image = UIImage(data: maskData) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .black
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            stack.addArrangedSubview(imageView)
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor,
                                              multiplier: image.size.height/max(1, image.size.width)).isActive = true
        } else {
            let missing = UILabel()
            missing.text = "本次没有生成诊断图，请查看下面的具体原因。"
            missing.numberOfLines = 0
            missing.textColor = .systemOrange
            stack.addArrangedSubview(missing)
        }
        let details = UITextView()
        details.isEditable = false
        details.isScrollEnabled = false
        details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.text = text
        details.backgroundColor = .secondarySystemBackground
        details.layer.cornerRadius = 10
        details.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        stack.addArrangedSubview(details)
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func copyInfo() {
        UIPasteboard.general.string = text
        navigationItem.rightBarButtonItem?.title = "已复制"
    }
}
