// CaptureModels.swift — 单次拍摄值类型；完整容器可交给本机编辑文档保存。
import Foundation

// 工程不再默认把所有类型隔离到 MainActor；相机可变状态只在 sessionQueue 访问。
enum CameraError: LocalizedError, Equatable, Sendable {
    case notAuthorized, unavailable, configurationFailed, captureFailed
    case photoLibraryDenied, busy, interrupted, captureTimedOut

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "未获得相机权限，请在设置中开启。"
        case .unavailable: return "当前没有可用相机画面，请使用真机并检查相机是否被占用。"
        case .configurationFailed: return "相机初始化失败，请退出拍照页后重试。"
        case .captureFailed: return "拍照失败，请重试。"
        case .photoLibraryDenied: return "未获得相册写入权限，照片无法保存。"
        case .busy: return "照片正在处理中，请稍候。"
        case .interrupted: return "相机被中断，请回到 App 后重试。"
        case .captureTimedOut: return "本次拍摄等待超时，相机正在恢复，请重新拍摄。"
        }
    }
}

/// 原始相机容器用于首次渲染，并可保存在可编辑照片中供拍后换焦。
struct CapturedPhoto: Sendable {
    let data: Data
    let depthRequested: Bool
    let hasDepthData: Bool
    let nativeDepth: NativeDepthSnapshot?
    let options: DepthOptions
    /// 快门时的硬件焦点；首次渲染解析出的焦点另存为编辑参数，不写入导出 JPEG。
    let transientDeviceFocus: NormalizedImagePoint?
    let captureSummary: String
    let nativePortraitMatte: NativePortraitMatteSnapshot?
    let captureID: Int64?
    /// 快门时冻结：后置主摄与前置优先原生深度及苹果滤镜；其他后置镜头用模型。
    let prefersAppleDepth: Bool
    /// 相机拍摄的苹果路径失败后重新估计模型深度；相册导入保留既有原生深度回退。
    let forceModelOnAppleFailure: Bool

    init(data: Data, depthRequested: Bool, hasDepthData: Bool,
         nativeDepth: NativeDepthSnapshot?, options: DepthOptions,
         transientDeviceFocus: NormalizedImagePoint?, captureSummary: String,
         nativePortraitMatte: NativePortraitMatteSnapshot? = nil, captureID: Int64? = nil,
         prefersAppleDepth: Bool = false, forceModelOnAppleFailure: Bool = false) {
        self.data = data
        self.depthRequested = depthRequested
        self.hasDepthData = hasDepthData
        self.nativeDepth = nativeDepth
        self.options = options
        self.transientDeviceFocus = transientDeviceFocus
        self.captureSummary = captureSummary
        self.nativePortraitMatte = nativePortraitMatte
        self.captureID = captureID
        self.prefersAppleDepth = prefersAppleDepth
        self.forceModelOnAppleFailure = forceModelOnAppleFailure
    }
}
