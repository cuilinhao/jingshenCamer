# 三物理镜头计算景深实施计划

> **For agentic workers:** Use superpowers:executing-plans with bounded parallel component implementation. 用户已批准上一轮方案，持续执行，不重复请求确认。

**Goal:** 三个物理镜头均可在本机生成计算景深，并保存可重复编辑的深度。

**Architecture:** 相机保持物理镜头选择；有效原生视差优先，无效或缺失时使用打包的 Depth Anything V2 Small FP16。新照片持久化传感器坐标的统一深度附件，使用支持前后景的可控渲染；旧文档仍使用原苹果渲染路径。

**Tech Stack:** Swift 5 / iOS 17，AVFoundation、Core ML、Core Image、Vision、ImageIO；无需网络运行和第三方运行 SDK。

**Spec:** 本对话用户已批准的“原生深度 + 本地 AI 深度估计、边缘处理、前后景渲染、拍后编辑”方案。

## Global Constraints

- 在 codex/apple-depth-rendering 工作；保留物理镜头 uniqueID 绑定，不为获取深度更换 RGB 镜头。
- 原图、深度均不可变；编辑从原图重新渲染，旧文档可读。
- 估计深度为相对视差，不能标为硬件测量或米数。
- 模型失败保留普通原图并明确提示；景深关闭不运行模型。
- 默认只做拍后处理，模型资产离线打包，模型许可和来源随代码提供。
- 不自动提交、推送或修改用户的 Xcode 界面状态；提交信息如需提交使用中文。

## Review Focus

- EXIF 1–8、镜像和竖屏的照片/深度/点击坐标始终一致。
- 无原生深度也能运行模型；关闭效果时不运行模型。
- 选择远景时近景真正失焦，选择近景时背景失焦；同深度区域保留完整原图细节。
- 缺失、损坏或被替换的持久化深度会报错，旧 schema 文档仍可读。
- 模型冷启动、错误、非方形输出、无效数值和移动端内存可控。

## Task 1: 离线 Core ML 深度估计

- [x] 下载 Apple 官方 Small FP16 mlpackage 并附许可、来源和哈希；由 Xcode 编译进应用。
- [x] 实现 `MonocularDepthEstimator(context: CIContext).estimate(image: CIImage) throws -> DepthRaster`。输入为已正向、原点归零图像；输出 top-left 相对视差（大=近），比例与输入一致；不裁掉图像。
- [x] 先写估计器数值/非方形几何测试，再实现转换；实际编译和推理模型验证输出有限、变化且尺寸有效，错误路径清晰。

## Task 2: 可控前后景渲染

- [x] 新增 `ComputationalDepthRenderer(context: CIContext, colorSpace: CGColorSpace).render(original: CIImage, depth: DepthRaster, focus: NormalizedImagePoint, aperture: Float) throws -> DepthBlurOutput`。
- [x] 重用经验证的近/远景分层、边缘引导上采样和原图清晰区域合成；不套用旧版整个人物强制清晰遮罩。原生人物分割只可作为边界辅助，不能覆盖深度语义。
- [x] 先写双层纹理像素测试验证近/远焦点和不同虚化强度，再实现；维持全分辨率输出，限制模糊工作尺寸。

## Task 3: 深度文档、处理流程及界面集成

- [x] 新增 `PhotoDepthData` 二进制 Codable 附件，包含版本、source、width/height 和浮点视差；统一存传感器 top-left 坐标，验证大小、覆盖和有限值。
- [x] `EditablePhotoDocument.depthData: Data?` 默认 nil；首次原子保存 depth.bin，manifest 保存 hash；更新时深度不可变，读时检查 hash，旧 schema 兼容。
- [x] `ProcessedPhoto.editDepthData: Data?` 携带新附件。默认 `.computational` 路径从原生或模型取得深度，选焦、渲染、缓存附件；保留 `.apple/.legacy` 显式对照和旧测试。
- [x] `PhotoEditingRenderer.render(sourceData:recipe:maximumDimension:depthData:)` 的 depthData 默认为 nil；有附件时走新渲染，没有附件时保留苹果旧路径。
- [x] 景深开关与虚拟光圈不再因缺原生深度禁用；展示原生/智能景深。拍摄和图库编辑都传同一附件。
- [x] 添加真实文档往返/损坏/不可变性，以及无原生深度的模型注入、开关关闭不推理、编辑重渲染测试。

## Task 4: 验证与交付

- [x] 更新脚本依赖清单、README 与真机验收步骤；保留旧版已知差异描述并区别新默认路径。
- [x] 运行新组件测试、实际模型 smoke、全部已有回归及 generic iOS 无签名构建，核对打包模型存在。
- [x] 独立代码审查改动，修复实际缺陷并重跑相关检查。真机三镜头画质/延迟标为待实拍，不把合成测试描述为真机验收。

## 执行记录

2026-09-22：四项任务完成。用户已批准方案，直接在指定分支实施。模型、渲染和文档存储分文件并行开发；独立审查检查集成及模型边界。前景/背景渲染采用已验证的 RGB 引导分层实现，不新增缺乏画质证据的人物分割修正；相应发丝边界效果明确保留为真机验收项。完整回归、实际模型推理及 iOS 构建通过。审查指出的原生焦点孔洞/邻域回退和诊断文案已修复，定向复核通过。详见 Documentation/2026-09-22-三镜头智能景深验证.md。

后续用户反馈主摄与此前苹果 API 版效果不同，明确接受主摄 RGB 固定、双摄/LiDAR 辅助深度，优先恢复苹果原生流程。此确认更新了上文主摄默认计算渲染和完全独立输入的约束；其他两颗镜头维持原方案。已添加采集策略和主摄路由回归，最终行为及验证详见 Documentation/2026-09-22-主摄苹果景深恢复.md。
