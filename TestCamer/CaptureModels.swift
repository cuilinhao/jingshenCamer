// CaptureModels.swift — 单次拍摄的值类型；无持久化。
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

/// 原始文件只在当前处理任务中存在。处理结果不携带以下瞬时深度或点位。
struct CapturedPhoto: Sendable {
    let data: Data
    let depthRequested: Bool
    let hasDepthData: Bool
    let nativeDepth: NativeDepthSnapshot?
    let options: DepthOptions
    /// 相机拥有的硬件焦点，在快门时读取，只供这一次渲染；不显示/保存坐标。
    let transientDeviceFocus: NormalizedImagePoint?
    let captureSummary: String
    let nativePortraitMatte: NativePortraitMatteSnapshot?
    let captureID: Int64?

    init(data: Data, depthRequested: Bool, hasDepthData: Bool,
         nativeDepth: NativeDepthSnapshot?, options: DepthOptions,
         transientDeviceFocus: NormalizedImagePoint?, captureSummary: String,
         nativePortraitMatte: NativePortraitMatteSnapshot? = nil, captureID: Int64? = nil) {
        self.data = data
        self.depthRequested = depthRequested
        self.hasDepthData = hasDepthData
        self.nativeDepth = nativeDepth
        self.options = options
        self.transientDeviceFocus = transientDeviceFocus
        self.captureSummary = captureSummary
        self.nativePortraitMatte = nativePortraitMatte
        self.captureID = captureID
    }
}
