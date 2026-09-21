# TestCamer · 拍后景深版

在你上传的 **TestCamer 2.zip** 上修改，保留原 UIKit 工程、Storyboard 入口、普通相机预览、闪光灯、切换摄像头、双指缩放、点按硬件对焦、重拍和保存流程。不是另外做一个无关项目。

## 打开和运行

解压后双击 `TestCamer.xcodeproj`，选择 **TestCamer** Scheme 和连接的 **iPhone 真机**，再运行。首次进入允许相机权限；点击保存时允许添加照片到相册。原工程的 Team 和 Bundle Identifier 保留；出现签名错误时，在 Signing & Capabilities 选择你自己的开发者 Team，并按需要修改 Bundle Identifier。

Deployment Target 已改成 **iOS 17.0**，界面仍是 UIKit，App 代码全部 Swift。使用能支持你真机系统版本的 Xcode；工程采用原有文件夹同步结构。没有第三方依赖、下载模型、API Key 或服务器配置。

真实相机深度交付和拍摄质量需要 iPhone 真机验证。另提供 macOS 原生 Core Image 像素回归和 iOS SDK 构建脚本，具体验证边界见下文。

## 这次实现的交互

进入后是普通相机画面，不运行实时虚化。顶部新增“拍后景深”开关和虚拟光圈，默认 f/1.8，可选 f/1.4～f/16；调节它只影响下一张照片。点按画面同时指定硬件对焦和下一张照片的景深清晰区域。

按快门后冻结本张照片的景深开关、虚拟光圈、临时点按焦点、方向和镜像信息，在同一次拍摄中获取照片与原生深度。等照片完成处理后，后台执行 Core Image 景深渲染，再显示成片。

结果页完整显示照片，标注“景深成片”或具体的普通照片降级原因，以及实际像素尺寸。景深成功时可按住“看原图”，这只是当前结果的内存对比，不是编辑器。点击保存写入完整分辨率的成片 JPEG；点击重拍清空本次内存数据并回到普通取景。

## 明确不做的事情

**不持久化聚焦位置，不创建 Recipe，不保存可重编辑原图/深度档案，不实现拍后重选焦点，也不保证系统“照片”App 能做重新对焦。** 当前只把平面化成片保存到相册。快门时的临时原文件可能包含系统深度附件，但只在内存中用于本次处理；最终重新编码的 JPEG 不复制这些辅助附件和相机私有元数据。

点按主体后，对焦位置只在本次拍摄中传给景深滤镜，并与照片/深度应用同一个 EXIF 方向和镜像。没有点按时先使用系统自动选择；若输出几乎未改变，再依据真实视差中的连续近景区域选择焦点重试。仍无明显变化时明确显示普通照片，不把滤镜返回图片当作景深成功。非人脸主体的边缘质量仍需真机实测。

没有原生深度能力时仍可普通拍照，不用 AI 估计深度，也不采用全图高斯模糊或抠图后统一模糊背景来冒充景深。设备支持但本次没给深度、深度过于无效/没有明显层次、原生滤镜不可用、渲染失败或效果不明显时，也明确回退普通成片，不显示“景深成功”。

## 输出约定

| 项目 | 本版约定 |
|---|---|
| 相机照片尺寸 | 从当前格式真实支持的尺寸中，优先选择不超过约 12 MP 的最大尺寸；若没有则选最小支持尺寸，不虚构分辨率。 |
| 成片文件 | sRGB、8 位普通 JPEG，编码质量 0.95；不是 RAW、HDR 保真或无损格式。 |
| 结果页预览 | 最大边 1600 像素，单独用于显示；保存时不用这个缩略图。 |
| 方向 | 照片与深度应用同一个 EXIF 方向，渲染和 JPEG 输出统一为正向；拍摄时冻结前后摄像头镜像。 |
| 焦点和元数据 | 不持久化聚焦位置；最终 JPEG 不复制相机 Maker、深度附件等原始元数据；虚拟 f 值不伪装成真实 EXIF 光圈。 |
| 构图 | 保留原 Demo 的满屏裁切预览；结果页完整显示照片，所以成片可能比取景显示范围更大。这版不另外裁成屏幕比例。 |
| 耗时 | 显示处理状态，未承诺某个固定耗时；拍摄回调有 45 秒兜底超时，Core Image 实际耗时待真机测试。 |

## 主要改动文件

| 文件 | 修改内容 |
|---|---|
| `TestCamer/CameraManager.swift` | 接入原生深度相机、照片深度开关、同次照片与深度交付、方向/镜像冻结、回调按 uniqueID 匹配、异常/中断恢复、受限变焦。 |
| `TestCamer/DepthPhotoProcessor.swift` | 拍后原生景深处理、点按/自动焦点、深度及像素变化检查、方向对齐、显示预览及完整成片 JPEG。 |
| `TestCamer/DepthCapturePolicy.swift` | 新增可独立测试的虚拟光圈、变焦边界、深度样本有效性和降级结果规则。 |
| `TestCamer/ViewController.swift` | 保留原界面基础，新增景深开关、光圈条、处理状态、结果信息与按住对比；保存完整 JPEG。 |
| `AppDelegate.swift`、`SceneDelegate.swift` | 显式 UI 主线程隔离，保留原入口。 |
| `TestCamer.xcodeproj` | 最低系统 17.0；取消对工作类型的隐式主线程隔离；新增共享运行 Scheme。 |

原工程已有的注释尽量保留；新增关键路径含中文注释和 `print`，没有自定义 `.metal`、Objective-C 或 C++ 文件。

## 检查与测试：区分已执行和未执行

初始交付的检查环境为 Linux + Swift 6.2.1，当时执行了：6 个 App Swift 文件语法解析、25 条纯 Swift 值规则检查、9 项源码契约检查、Info.plist/pbxproj 语法检查和 XML/资源 JSON 解析。对应输出保存在 `Documentation/verification-local.txt`。

**Swift 语法解析和源码契约不等于运行时效果测试。** 本次修复新增 `Tests/DepthRenderingTests.swift`：将带已知深度的非人脸偏心主体编码为 HEIC，再调用生产处理器，逐区域检查背景虚化、主体细节、光圈差异、方向/镜像和降级结果。它可在 Mac 上运行，但不能替代 iPhone 相机交付、权限、中断和实际视觉质量验收。最新验证记录见 `Documentation/景深修复验证.md`。

复跑跨平台检查：

```bash
bash Scripts/verify_local.sh
```

在装有完整 Xcode 的 Mac 上检查 SDK 构建：

```bash
bash Scripts/verify_on_mac.sh
```

后者先执行源码/规则及原生像素回归，再构建通用 iOS 目标，不安装、不签名、不替代真机测试。也可单独运行 `bash Scripts/verify_depth_rendering.sh`。手动操作项目运行更直接。真机测试步骤见 `Documentation/真机验收.md`。

## Xcode 控制台关键日志

`[Capability]` 显示每个候选相机是否支持当前配置下的照片深度；`[Camera]` 显示启动、分辨率和合法变焦范围；`[Capture ...]` 显示是否请求深度、是否真正交付；`[Depth]` 显示深度样本范围、最终结果和渲染耗时。

若界面显示普通照片，先检查结果提示和 `outcome`，不要只依据设备名称推断必然有可用深度。

## 原生 API 依据

以下是本次核对过的 Apple 官方接口，具体效果仍依赖设备、系统与场景。

- [Capturing photos with depth](https://developer.apple.com/documentation/avfoundation/capturing-photos-with-depth)
- [AVCapturePhotoOutput.isDepthDataDeliverySupported](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isdepthdatadeliverysupported)
- [AVCapturePhotoSettings.isDepthDataDeliveryEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/isdepthdatadeliveryenabled)
- [AVDepthData](https://developer.apple.com/documentation/avfoundation/avdepthdata)
- [CIImage.init(depthData:)](https://developer.apple.com/documentation/coreimage/ciimage/init(depthdata:))
- [CIContext.depthBlurEffectFilter](https://developer.apple.com/documentation/coreimage/cicontext/depthblureffectfilter(for:disparityimage:portraiteffectsmatte:orientation:options:))

