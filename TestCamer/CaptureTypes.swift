// 拍摄与渲染共享的不可变值类型；不依赖相机会话，可直接用于原生图像回归测试。
import Foundation

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

/// 原始文件（可能临时嵌有深度）仅在内存中用于这一次处理，不写磁盘、不直接保存到相册。
struct CapturedPhoto: Sendable {
    let data: Data
    let depthRequested: Bool
    let hasDepthData: Bool
    let options: DepthOptions
}

