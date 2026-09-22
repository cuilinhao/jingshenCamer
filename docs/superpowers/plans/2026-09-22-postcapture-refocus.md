# 拍后换焦 Implementation Plan

> **For agentic workers:** 使用 executing-plans 实施；存储和渲染由独立子任务并行实现，主任务负责交互集成与验证。

**Goal:** 支持 App 内拍后换焦、光圈调整、本机重编辑和一致的相册导出。
**Architecture:** 原始相机容器不可变；可编辑文档分离保存初始与当前参数。后台串行渲染与请求代数保证只有最新结果展示；本机存储与 UIKit 页面分离。
**Tech Stack:** Swift 5、iOS 17+、UIKit、Core Image、ImageIO、Foundation、PhotoKit。
**Spec:** docs/superpowers/specs/2026-09-22-postcapture-refocus-design.md

## Global Constraints

- 使用原始容器和公开苹果 API；不递归虚化。
- 全部图像处理和源文件存储留在本机。
- 系统相册导出完整分辨率 JPEG，不保证系统原生重编辑控件。
- 不修改用户 xcuserstate；本次不安装到手机，不自动提交或发布。

## Review Focus

- 新点位到来时旧渲染完成，不可覆盖新焦点或保存过期参数。
- EXIF 镜像/旋转和 aspect-fit 黑边，点选应对应正确深度。
- 保存失败、损坏文件或重启后读取，不可丢失以前有效照片。
- 导出时参数变化，必须锁定并导出当次可确认的结果。
- 非景深照片、失败渲染、退出编辑时队列残留，应正确回退并释放状态。

## Task 1: 可编辑数据与存储

Files: PhotoEditingModels.swift, EditablePhotoStore.swift, Tests/PhotoEditingStoreTests.swift, Scripts/verify_photo_editing_store.sh。
Interfaces: PhotoEditRecipe(aperture:sensorFocus:) Codable/Equatable；EditablePhotoDocument(id:createdAt:updatedAt:sourceData:initialRecipe:recipe:previewData:)；actor EditablePhotoStore(rootDirectory:) 的 save/load(id:)/list/delete(id:)。
- [x] 先写真实临时目录测试：重建 store 读取源文件/参数、更新后原始效果保留、删除所有资源、损坏文件隔离、非法参数拒绝。
- [x] 观察缺失能力的失败，再实现原子文档提交；运行存储测试通过。

## Task 2: 原图重渲染

Files: PhotoEditingRenderer.swift, DepthPhotoProcessor.swift, Tests/PhotoEditingRenderTests.swift, Scripts/verify_photo_editing_render.sh。
Interfaces: PhotoEditingRenderer.render(sourceData:recipe:maximumDimension:) async throws -> PhotoEditingRenderResult(jpegData,pixelWidth,pixelHeight,usedMetadataCompatibility)；originalPreview(sourceData:maximumDimension:)；ProcessedPhoto.editRecipe 可选。
- [x] 合成有纹理前后深度照片，验证换焦和光圈改变实际像素、预览与导出尺寸、原始输入不变、无深度失败。
- [x] 记录初次渲染真实选定的 sensorFocus；适配器复用原 AppleDepthRenderer，不重复实现景深算法。
- [x] 运行真实 Core Image 测试通过，保留既有测试入口。

## Task 3: 编辑交互与集成

Files: PhotoEditingSession.swift, PhotoEditorViewController.swift, EditablePhotoLibraryViewController.swift, ViewController.swift, Tests/PhotoEditingSessionTests.swift。
- [x] 测试 aspect-fit 留白、EXIF 1–8 坐标、连续新请求和失败/结束后过期结果失效。
- [x] 编辑器显示点选框、光圈滑杆、原图比较、恢复初始、状态和相册导出；预览请求合并且自动保存成功版本。
- [x] 拍摄成功先保存初始可编辑版本，再自动进入编辑器；库入口可打开/删除；关闭编辑后清理拍摄结果回相机。
- [x] 运行协调器测试与 iOS SDK 编译。

## Task 4: 验证与说明

- [x] 更新 README 和真机验收说明，修改原来仅 JPEG 的过时约束和测试。
- [x] Scripts/verify_on_mac.sh 与新增软件回归通过；严格前景虚化验收的 8 项失败单独记录。
- [x] 独立审查生命周期、数据持久化和画面一致性，修复重要发现并再次验证。

## 执行结果与限制

已完成上述编辑/存储/页面实现，未自动提交。完整 `bash Scripts/verify_on_mac.sh` 退出 0：iOS SDK 构建、原有回归及新增存储 54、会话 30、编辑渲染 145 项通过。`git diff --check` 通过。独立数据层与 UI 审查发现的 staging 遗留和日志分享遮挡编辑器已修复。

画质验收与软件回归分开记录：严格前景探针 153 项中 8 项失败（EXIF 1–8 点远处后近景仍清晰）。macOS 与 iOS 27 模拟器原生探针一致。未伪装此项为通过，未擅自加入私有参数或额外前景算法；真实手机画质尚未验证。详见 Documentation/2026-09-22-拍后换焦验收.md。

验证日志：/tmp/testcamer-refocus-final-verification.log；严格日志：/tmp/testcamer-edit-render-strict.log。
