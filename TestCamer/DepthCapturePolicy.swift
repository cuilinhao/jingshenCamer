//
//  DepthCapturePolicy.swift
//  TestCamer
//
//  拍后景深的纯值规则，可脱离 iOS 相机运行回归测试。
//  对焦点只作为本次快门的内存参数，不写入成片或可重编辑档案。
//
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct DepthOptions: Sendable, Equatable {
    let enabled: Bool
    let aperture: Float
    /// 传感器归一化坐标（左上为原点）；nil 表示使用自动景深选择。
    let focusPoint: CGPoint?

    init(enabled: Bool, aperture: Float, focusPoint: CGPoint? = nil) {
        self.enabled = enabled
        self.aperture = aperture.isFinite ? min(max(aperture, 1.4), 16) : 1.8
        if let point = focusPoint, point.x.isFinite, point.y.isFinite {
            self.focusPoint = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        } else {
            self.focusPoint = nil
        }
    }
}

enum DepthRenderOutcome: String, Sendable {
    case applied
    case disabled
    case unsupported
    case missingDepth
    case invalidDepth
    case renderFailed
    case noVisibleEffect

    var isDepthApplied: Bool { self == .applied }

    var message: String {
        switch self {
        case .applied: return "景深成片"
        case .disabled: return "普通照片 · 景深已关闭"
        case .unsupported: return "普通照片 · 当前相机不支持原生深度"
        case .missingDepth: return "普通照片 · 本次未获得深度数据"
        case .invalidDepth: return "普通照片 · 深度无效或场景层次不足"
        case .renderFailed: return "普通照片 · 本次景深处理未成功"
        case .noVisibleEffect: return "普通照片 · 本次景深变化不明显，可点按近处主体或调大光圈"
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
