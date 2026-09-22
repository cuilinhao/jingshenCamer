# 苹果景深渲染与同帧对比 Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the bounded renderer task; the coordinating agent integrates capture, processing and UI. Track verification below.

**Goal:** 默认使用苹果公开景深渲染，以用户提供的 iPhone 18 系统 f/1.4 照片为视觉验收参考，同时提供同帧旧版对比。

**Architecture:** 保留同一次 AVCapturePhoto 的未虚化彩色图、深度及可用辅助遮罩到内存编码容器，由 CIContext.depthBlurEffectFilter 创建官方滤镜。旧版渲染仅用于显式标注的同帧对照。官方路径失败时返回普通照片与具体原因，不冒充成功。

**Tech Stack:** Swift 5、UIKit、AVFoundation、Core Image、ImageIO，iOS 17+。

**Spec:** 本任务对话中已批准的方案及当前用户“按照你的方案来改代码”。实现已获授权，不重复设置审批环节。

## Global Constraints

- 只修改 Desktop/TestCamer；保留用户已有 Xcode UI 状态更改。
- iOS 17.0；不增加第三方依赖、网络、模型或自定义 Metal。
- 仅保存烘焙 JPEG；原图、焦点及深度只在内存中参与这次拍摄。
- 苹果路径不使用旧版整个人物硬保护合成，不把旧版输出当作系统效果。
- 参考 HEIC 已有虚化，不能二次虚化后宣称通过视觉验收。

## Review Focus

- 焦点在图像边缘、旋转或镜像时仍对应正确深度：用八种 EXIF 与非中心纹理验证。
- 无辅助深度、无效数据、滤镜不可用时回退明确，无假成功。
- 同帧对比保持同原图、深度、焦点和光圈；保存始终使用默认结果。
- 原生遮罩未交付时不能把其他人物拼回清晰背景。
- 完整尺寸和保存后的无深度附件行为保留；合成测试不等于真机画质验收。

### Task 1: 官方渲染适配与原生测试

Files: 新建 TestCamer/AppleDepthRenderer.swift、Tests/AppleDepthRendererTests.swift、Scripts/verify_apple_depth_on_mac.sh。

Interface: AppleDepthRenderer(context: CIContext).render(photoData: Data, aperture: Float, sensorFocus: NormalizedImagePoint?) throws -> AppleDepthOutput；输出已转正的 CIImage 与不含点位的 notes。

- [x] 用实际 Core Image + 内存 HEIC 合成样本建立会失败的测试：无深度拒绝、不同焦点/光圈改变实际纹理、八种方向保持选择位置。
- [x] 验证 factory 输出方向和 inputFocusRect 坐标，不凭参数名猜测。
- [x] 实现容器输入及参数验证；缺失数据和输出异常抛错。
- [x] 运行新增 macOS 原生测试。

### Task 2: 采集与处理集成

Files: CameraManager.swift、DepthPhotoProcessor.swift、DepthCapturePolicy.swift、Tests/NativeRenderSmokeTests.swift、现有测试脚本。

- [x] 添加行为回归：默认官方路径不得退回旧版；无深度回退；同帧对比和导出无深度元数据。
- [x] 保留内存附件及其元数据，按设备能力请求 hair/glasses，不持久化输入。
- [x] 默认官方路径、旧版显式入口及同帧对比；官方诊断呈现输出变化图并说明不是内部虚化遮罩。
- [x] 运行原有及新增渲染检查，更新已被需求替代的源码约束。

### Task 3: 界面、回放与交付验证

Files: ViewController.swift、DepthDiagnosticsViewController.swift、Tests/DepthPhotoReplay.swift、Scripts/replay_depth_photo.sh、README.md。

- [x] 默认 f/1.4，结果明确展示苹果景深、原图及旧版对比；保存始终采用苹果结果或其明确普通照片回退。
- [x] 离线回放分别输出两套算法的同帧结果，标注参考图重处理不能作为验收。
- [x] 运行 Scripts/verify_on_mac.sh、新增测试和 iOS SDK 构建；独立代码审查并修复问题。
- [x] 记录已验证与尚需真机拍摄确认的边界。

## 执行记录

- 已在当前工作目录创建 codex/apple-depth-rendering 分支；当前用户仅有 xcuserstate 更改，不触碰。
- 用户已明确要求实施，因此在本任务内连续执行，不再为计划文档重复要求确认。
- Ruling: 当前 macOS 原生辅助元数据使官方 filter 直接返回 input 对象；仅在这种已用像素验证的直通情况下做明示的苹果元数据兼容处理，保留真实数值、其他输入及单独校准。结果页标注，失败不切回旧版。
- Task 1 complete: 八种 EXIF、选焦、光圈、合法/无效输入及兼容标注共 58 项检查通过；无效深度新增 RED→GREEN 已记录。
- Task 2 complete: 同帧对比、主结果保存、附件清理和普通照片回退整合回归共 94 项检查通过。
- Task 3 complete: iOS SDK 构建通过；离线同帧合成回放成功；独立审查未发现重要问题；真机画质待新样本验收，未冒充完成。
