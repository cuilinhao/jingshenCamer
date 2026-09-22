//
//  DepthCapturePolicy.swift
//  TestCamer
//
//  拍后景深的纯值规则，可脱离 iOS 相机运行回归测试。
//  不包含、也不持久化聚焦坐标。
//
import Foundation

enum DepthRenderingMethod: String, Sendable {
    case apple
    case legacy

    var title: String { self == .apple ? "苹果景深" : "旧版景深" }
}

struct DepthOptions: Sendable, Equatable {
    let enabled: Bool
    let aperture: Float

    init(enabled: Bool, aperture: Float) {
        self.enabled = enabled
        self.aperture = aperture.isFinite ? min(max(aperture, 1.4), 16) : 1.8
    }
}

enum DepthRenderOutcome: String, Sendable {
    case applied
    case weakEffect
    case disabled
    case unsupported
    case missingDepth
    case invalidDepth
    case renderFailed
    case insufficientSeparation
    case focusUnavailable
    case alignmentMismatch

    var isDepthApplied: Bool { self == .applied }
    var canCompare: Bool { self == .applied || self == .weakEffect }

    var message: String {
        switch self {
        case .applied: return "已生成景深成片"
        case .weakEffect: return "已处理 · 本次可见变化较弱，请查看诊断"
        case .disabled: return "普通照片 · 景深已关闭"
        case .unsupported: return "普通照片 · 当前相机不支持原生深度"
        case .missingDepth: return "普通照片 · 本次未获得深度数据"
        case .invalidDepth: return "普通照片 · 深度无效或场景层次不足"
        case .renderFailed: return "普通照片 · 本次景深处理未成功"
        case .insufficientSeparation: return "普通照片 · 前后深度差不足"
        case .focusUnavailable: return "普通照片 · 所选区域缺少有效深度"
        case .alignmentMismatch: return "普通照片 · 深度与照片比例不一致"
        }
    }
}

enum DepthCapturePolicy {
    static let apertures: [Float] = [1.4, 1.8, 2, 2.8, 4, 5.6, 8, 11, 16]
    static let captureTimeout: Double = 45
    static let preferredPhotoPixelCount: Int64 = 12_600_000

    static func aperture(sliderValue: Float) -> Float {
        guard sliderValue.isFinite else { return 1.8 }
        let index = Int(min(max(sliderValue.rounded(), 0), Float(apertures.count - 1)))
        return apertures[index]
    }

    /// 启用原生深度后，可用变焦上下限可能改变。不能只夹取到 [1, videoMaxZoomFactor]。
    static func clampedZoom(_ value: Double, minimum: Double, maximum: Double) -> Double {
        let lower = minimum.isFinite && minimum > 0 ? minimum : 1
        let hardwareUpper = maximum.isFinite ? max(maximum, lower) : lower
        let upper = max(lower, min(hardwareUpper, 8))
        return min(max(value.isFinite ? value : lower, lower), upper)
    }

    /// 只判定数据是否适合尝试渲染，不把相对视差称为精确的真实距离。
    static func usableDepth(valid: Int, total: Int, minimum: Float, maximum: Float) -> Bool {
        guard total > 0, valid > 0, valid <= total,
              Double(valid) / Double(total) >= 0.25,
              minimum.isFinite, maximum.isFinite, minimum > 0 else { return false }
        return maximum - minimum > max(0.000_01, maximum * 0.001)
    }
}
